#!/usr/bin/env bash
# kit-pr-pipeline.sh [options] <worktree> <pr> <remote-branch>
#
# Kit-maintenance tool (kit issue #2212; outside the research toolbelt core): take one open kit PR to merged:
#   restack onto the base -> push -> [size-check hook] -> RDD (native review) -> ONE flock'd full gate
#   -> CI wait -> merge-gate --merge.
# Each step is also callable on its own: kit-rdd-start.py, kit-rdd-drive.py, kit-gate.sh, kit-wait-merge.sh.
#
# Options:
#   --consent granted   record the maintainer's STANDING grant to start the native review for this candidate.
#                       Never inferred: without it the provider's consent envelope is printed in full and the
#                       run stops with consent-required (exit 15).
#   --serial            run the gate serially: `run-all.sh --prove-teeth` with NO -j. Serial is the CLAUDE.md
#                       section 5 reference for the quiet-tree gate; the default stays `-j 4 --prove-teeth`
#                       (the maintainer's gate of record, with -j attribution). Use --serial when a -j result is in
#                       doubt (timing-only failure, unattributed leak) or the machine is loaded. Not with --gate-cmd.
#   --no-gate           skip the full gate (a hook point: an impacted-suite gate, #2201, runs it instead)
#   --gate-cmd CMD      run CMD (bash -c, inside the worktree) as the gate instead of the full
#                       `run-all.sh -j 4 --prove-teeth` (hook point for #2201 / the merge train #2213)
#   --size-check CMD    run CMD (bash -c, inside the worktree; env KIT_PR, KIT_WORKTREE) before RDD; a non-zero
#                       exit stops with size-check-failed (hook point for #2214; absent = no-op)
#   --state-dir DIR     state (rdd-<pr>.json, gate.lock, gate-<label>.log); default
#                       ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/pipeline; refused inside the worktree
#   --base-ref REF      restack base and RDD base (default origin/main)
#   --remote NAME       remote to fetch and push (default origin)
#   --dry-run           print the plan (`kit-pr-pipeline: plan: ...`); mutate nothing, call no git/gh/gentle-ai
# Environment: KIT_RETRY_SLEEP (retry backoff base, default 5 s) and, for kit-wait-merge.sh, KIT_POLL_SLEEP,
# KIT_POLL_MAX, KIT_MERGE_SLEEP, KIT_MERGE_TRIES, KIT_MERGE_GATE.
#
# Typed exit states (the last line is `kit-pr-pipeline: <state>: ...`; registered in reason-codes.v1.md):
#   state              exit  meaning
#   merged               0   the PR merged
#   usage                2   bad arguments, missing worktree, or a state dir inside the worktree
#   degraded             3   a runtime dependency is missing (git gh gentle-ai python3, flock unless --no-gate)
#   restack-conflict    11   the merge of the base left unmerged paths; it was aborted, nothing was pushed
#   bad-base-ref        23   the base ref does not resolve (git merge-base failed); nothing was merged or pushed
#   dirty-tree          24   tracked files have uncommitted changes; stopped before any fetch, merge or push
#   restack-error       25   the merge failed WITHOUT unmerged paths (not a conflict); nothing was pushed
#   push-failed         12   fetch/push still failing after 3 tries (fetch failure is fetch-failed, 21)
#   rdd-not-approved    13   the review stopped short of acknowledgement: `rdd-stop: <reason_code>` is printed
#                            (correction_required, lens_context_budget_exceeded, ...); no automatic recovery
#   rdd-start-error     14   the review could not be started
#   consent-required    15   the consent envelope was printed; re-run with --consent granted
#   gate-failed         16   the gate exited non-zero; CI and merge were not attempted
#   gate-lock-timeout   22   the gate lock was not obtained in time (another gate is running); not a gate failure
#   ci-failed           17   a CI check failed
#   merge-degraded      18   merge-gate stayed degraded through every try
#   not-merged          19   merge-gate refused or the PR is still not MERGED
#   size-check-failed   20   the --size-check hook exited non-zero
#   fetch-failed        21   `git fetch` still failing after 3 tries
#   (rdd-not-due is informational: no review is due, the pipeline goes on; kit-rdd-start.py itself exits 10)
# Never edit this file, or a sibling tool, in place while a pipeline started from it is running: bash reads a
# script incrementally, so an in-place edit corrupts the live run. Copy, edit the copy, start new runs from it.
set -u
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
# shellcheck disable=SC2034 # read by kit-maint-common.sh
KIT_TOOL=kit-pr-pipeline
# shellcheck source=kit-maint-common.sh
. "$_RSDD_SELF/kit-maint-common.sh" || { echo "kit-pr-pipeline: degraded: kit-maint-common.sh unavailable" >&2; exit 3; }

dry_run=0 consent='' serial=0 no_gate=0 gate_cmd='' size_check='' state='' base=origin/main remote=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --consent) [ "${2:-}" = granted ] || kit_fail 2 usage "--consent takes the single value: granted"; consent=granted; shift 2 ;;
    --serial) serial=1; shift ;;
    --no-gate) no_gate=1; shift ;;
    --gate-cmd) [ $# -ge 2 ] || kit_fail 2 usage "--gate-cmd needs a value"; gate_cmd="$2"; shift 2 ;;
    --size-check) [ $# -ge 2 ] || kit_fail 2 usage "--size-check needs a value"; size_check="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || kit_fail 2 usage "--state-dir needs a value"; state="$2"; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || kit_fail 2 usage "--base-ref needs a value"; base="$2"; shift 2 ;;
    --remote) [ $# -ge 2 ] || kit_fail 2 usage "--remote needs a value"; remote="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^[^#]/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) kit_fail 2 usage "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 3 ] || kit_fail 2 usage "kit-pr-pipeline.sh [options] <worktree> <pr> <remote-branch>"
[ "$serial" -eq 0 ] || [ -z "$gate_cmd" ] || kit_fail 2 usage "--serial cannot be combined with --gate-cmd"
wt="$1"; pr="$2"; br="$3"
case "$pr" in ''|*[!0-9]*) kit_fail 2 usage "pr must be a number: $pr" ;; esac
[ -d "$wt" ] || kit_fail 2 usage "worktree is not a directory: $wt"
wt="$(CDPATH='' cd -- "$wt" && pwd -P)" || kit_fail 2 usage "cannot resolve the worktree"

deps=(git gh gentle-ai python3)
[ "$no_gate" -eq 1 ] || deps+=(flock)
kit_probe_deps "${deps[@]}" || exit 3

[ -n "$state" ] || state="$(kit_state_dir)"
state_phys="$(kit_phys_path "$state")" || kit_fail 2 usage "cannot resolve --state-dir $state"
case "$state_phys/" in "$wt"/*) kit_fail 2 usage "--state-dir $state_phys is inside the worktree; state never lives in the repo" ;; esac
state="$state_phys"

if [ "$dry_run" = 1 ]; then
  kit_say "plan: 1. fetch $remote; restack: merge $base into the branch only when it is behind (conflict -> abort, exit 11)"
  kit_say "plan: 2. push HEAD to $remote:$br (3 tries)"
  kit_say "plan: 3. size-check hook: ${size_check:-none}"
  kit_say "plan: 4. RDD: assess $base..HEAD; if due, STATUS -> START; consent ${consent:-NOT given (the envelope is printed, exit 15)}; then follow the review to acknowledgement"
  kit_say "plan: 5. gate: $([ "$no_gate" -eq 1 ] && echo skipped || echo "flock'd ${gate_cmd:-run-all.sh $([ "$serial" -eq 1 ] && echo '--prove-teeth (serial)' || echo '-j 4 --prove-teeth')}")"
  kit_say "plan: 6. CI wait on PR #$pr, then merge-gate --merge (degraded retried)"
  kit_say "plan: state dir $state; nothing was run"
  exit 0
fi

cd "$wt" || kit_fail 2 usage "cannot cd to $wt"
mkdir -p "$state" || kit_fail 2 usage "cannot create state dir $state"

# 1. restack
[ -z "$(git status --porcelain --untracked-files=no)" ] || kit_fail 24 dirty-tree "#$pr: tracked files have uncommitted changes; commit or stash them"
kit_retry 3 git fetch -q "$remote" || kit_fail 21 fetch-failed "git fetch $remote failed after 3 tries (#$pr)"
git merge-base --is-ancestor "$base" HEAD
anc=$?
if [ "$anc" -gt 1 ]; then kit_fail 23 bad-base-ref "#$pr: $base does not resolve (git merge-base rc=$anc)"; fi
if [ "$anc" -eq 1 ] && ! git merge -q --no-edit "$base"; then
  if [ -n "$(git ls-files -u)" ]; then
    git merge --abort
    kit_fail 11 restack-conflict "#$pr does not merge cleanly onto $base; the merge was aborted"
  fi
  kit_fail 25 restack-error "#$pr: merging $base failed without a conflict; resolve by hand"
fi
# 2. push
kit_retry 3 git push -q "$remote" "HEAD:$br" || kit_fail 12 push-failed "git push $remote HEAD:$br failed after 3 tries (#$pr)"
kit_say "head $(git rev-parse --short HEAD)"

# 3. size-check hook
if [ -n "$size_check" ]; then
  KIT_PR="$pr" KIT_WORKTREE="$wt" bash -c "$size_check" || kit_fail 20 size-check-failed "--size-check exited non-zero (#$pr)"
fi

# 4. RDD
rdd_json="$state/rdd-$pr.json"
start_args=(--base-ref "$base")
[ "$consent" = granted ] && start_args+=(--consent granted)
python3 -I "$_RSDD_SELF/kit-rdd-start.py" "${start_args[@]}" "$wt" "$rdd_json"
rc=$?
case "$rc" in
  0)
    drive_log="$state/rdd-drive-$pr.log"
    python3 -I "$_RSDD_SELF/kit-rdd-drive.py" "$wt" "$rdd_json" > "$drive_log" 2>&1
    drc=$?
    if [ "$drc" -eq 15 ]; then cat "$drive_log"; else grep -vE '^(RUN|LAUNCH)' "$drive_log" | cut -c1-300 | tail -6; fi
    case "$drc" in
      0) ;;
      3) kit_fail 3 degraded "kit-rdd-drive.py reported a missing dependency" ;;
      15) kit_fail 15 consent-required "the review document is a consent envelope (#$pr)" ;;
      *) kit_fail 13 rdd-not-approved "#$pr: the review did not reach acknowledgement (rc=$drc, log $drive_log)" ;;
    esac ;;
  10) kit_say "rdd-not-due: #$pr needs no native review; continuing" ;;
  15) kit_fail 15 consent-required "#$pr: re-run with --consent granted to record the maintainer's standing grant" ;;
  3) kit_fail 3 degraded "kit-rdd-start.py reported a missing dependency" ;;
  *) kit_fail 14 rdd-start-error "#$pr: kit-rdd-start.py exited $rc" ;;
esac

# 5. gate
if [ "$no_gate" -eq 0 ]; then
  gate_args=(--state-dir "$state")
  [ -n "$gate_cmd" ] && gate_args+=(--cmd "$gate_cmd")
  [ "$serial" -eq 1 ] && gate_args+=(--serial)
  bash "$_RSDD_SELF/kit-gate.sh" "${gate_args[@]}" "$wt" "pr$pr"
  grc=$?
  case "$grc" in
    0) ;;
    2) kit_fail 2 usage "#$pr: kit-gate.sh rejected its arguments" ;;
    3) kit_fail 3 degraded "kit-gate.sh reported a missing dependency" ;;
    22) kit_fail 22 gate-lock-timeout "#$pr: another gate holds the lock; re-run when it finishes" ;;
    *) kit_fail 16 gate-failed "#$pr: the gate exited non-zero (kit-gate rc=$grc); CI and merge were not attempted" ;;
  esac
fi

# 6. CI wait + merge
bash "$_RSDD_SELF/kit-wait-merge.sh" --base-ref "$base" "$wt" "$pr"
rc=$?
case "$rc" in
  0) kit_say "merged: #$pr"; exit 0 ;;
  3) kit_fail 3 degraded "kit-wait-merge.sh reported a missing dependency" ;;
  17) kit_fail 17 ci-failed "#$pr" ;;
  18) kit_fail 18 merge-degraded "#$pr: merge-gate stayed degraded" ;;
  *) kit_fail 19 not-merged "#$pr (kit-wait-merge.sh exited $rc)" ;;
esac
