#!/usr/bin/env bash
# kit-wait-merge.sh [--base-ref REF] [--expect-head SHA] <worktree> <pr>
#
# Kit-maintenance tool (kit issue #2212): wait for the PR's CI checks, then run `merge-gate.sh --merge` and
# confirm the PR is MERGED. gh calls run inside <worktree> (the repo is derived from it).
# CI wait: `gh pr checks <pr>` is polled; rc 0 = green; any `fail` line = ci-failed; otherwise (pending, or a
# network blip) it sleeps and polls again, at most KIT_POLL_MAX times (default 120, KIT_POLL_SLEEP default 60 s).
# On a poll timeout merge-gate decides (it reads the exact head's check-runs and refuses ci_pending).
# Merge: up to KIT_MERGE_TRIES (default 3) runs of merge-gate (KIT_MERGE_GATE overrides its path; default
# ../merge-gate.sh next to this directory), KIT_MERGE_SLEEP (default 30 s) apart. Retried: merge-gate rc 3
# (degraded), `refuse: ci_pending`, or an allow that has not shown MERGED yet. Any other refusal stops at once.
# Never edit this file in place while a run started from it is live (bash reads scripts incrementally).
#
# Typed exit states (printed as `kit-wait-merge: <state>`):
#   0   merged          the PR state is MERGED
#   2   usage           bad arguments
#   3   degraded        gh missing, or merge-gate.sh not found
#   17  ci-failed       a CI check failed (the failing lines are printed)
#   18  merge-degraded  merge-gate stayed degraded (rc 3) through every try
#   19  not-merged      refused (review_due, head_mismatch, ...) or still not MERGED after the tries
#   33  merged-out-of-band  --expect-head SHA was given and the PR is MERGED at a different head (not the gated one)
# --expect-head SHA (kit issue #2213): after MERGED, read headRefOid + mergeCommit and require headRefOid == SHA.
set -u
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
# shellcheck disable=SC2034 # read by kit-maint-common.sh
KIT_TOOL=kit-wait-merge
# shellcheck source=kit-maint-common.sh
. "$_RSDD_SELF/kit-maint-common.sh" || { echo "kit-wait-merge: degraded: kit-maint-common.sh unavailable" >&2; exit 3; }

base=origin/main expect_head=
while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref) [ $# -ge 2 ] || kit_fail 2 usage "--base-ref needs a value"; base="$2"; shift 2 ;;
    --expect-head) [ $# -ge 2 ] || kit_fail 2 usage "--expect-head needs a value"; expect_head="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^[^#]/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) kit_fail 2 usage "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || kit_fail 2 usage "kit-wait-merge.sh [--base-ref REF] <worktree> <pr>"
wt="$1"; pr="$2"
case "$pr" in ''|*[!0-9]*) kit_fail 2 usage "pr must be a number: $pr" ;; esac
[ -d "$wt" ] || kit_fail 2 usage "worktree is not a directory: $wt"
kit_probe_deps gh || exit 3
mg="${KIT_MERGE_GATE:-$_RSDD_SELF/../merge-gate.sh}"
[ -f "$mg" ] || kit_fail 3 degraded "merge-gate.sh not found: $mg"
cd "$wt" || kit_fail 2 usage "cannot cd to $wt"

poll_max="${KIT_POLL_MAX:-120}"; tries="${KIT_MERGE_TRIES:-3}"
n=0; green=0
while [ "$n" -lt "$poll_max" ]; do
  n=$((n + 1))
  out="$(gh pr checks "$pr" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then green=1; break; fi
  if grep -qE '\bfail\b' <<<"$out"; then
    grep -E '\bfail\b' <<<"$out"
    kit_fail 17 ci-failed "a CI check failed for #$pr"
  fi
  sleep "${KIT_POLL_SLEEP:-60}"
done
[ "$green" -eq 1 ] || kit_say "ci-wait: no green result after $poll_max polls; merge-gate decides"

last=''
for ((i = 1; i <= tries; i++)); do
  mgout="$(bash "$mg" --cwd "$wt" --base-ref "$base" --merge "$pr" 2>&1)"; mrc=$?
  printf '%s\n' "$mgout" | tail -5
  st="$(kit_retry 3 gh pr view "$pr" --json state -q .state)"
  if [ "$st" = MERGED ]; then
    if [ -n "$expect_head" ]; then
      # MERGED is only the train's merge when GitHub merged the head that was gated (kit issue #2213 S1)
      info="$(kit_retry 3 gh pr view "$pr" --json headRefOid,mergeCommit -q '.headRefOid + " " + (.mergeCommit.oid // "")')"
      [ -n "$info" ] || kit_fail 18 merge-degraded "#$pr is MERGED but its head and merge commit could not be read"
      if [ "${info%% *}" != "$expect_head" ]; then
        kit_fail 33 merged-out-of-band "#$pr is MERGED at head ${info%% *}, not the gated head $expect_head"
      fi
      kit_say "merged: #$pr (merge commit ${info#* })"; exit 0
    fi
    kit_say "merged: #$pr"; exit 0
  fi
  if [ "$mrc" -eq 3 ]; then last=degraded
  elif [ "$mrc" -eq 0 ] || grep -q 'refuse: ci_pending' <<<"$mgout"; then last=pending
  else last=refused; break
  fi
  kit_say "retry $i/$tries ($last)"
  sleep "${KIT_MERGE_SLEEP:-30}"
done
if [ "$last" = degraded ]; then kit_fail 18 merge-degraded "merge-gate stayed degraded for #$pr"; fi
kit_fail 19 not-merged "#$pr is not merged ($last)"
