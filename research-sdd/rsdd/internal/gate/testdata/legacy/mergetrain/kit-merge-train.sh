#!/usr/bin/env bash
# kit-merge-train.sh [options] <pr> [<pr>...]
#
# Kit-maintenance tool (kit issue #2213; outside the research toolbelt core): gate a batch of approved kit PRs ONCE
# on a combined "train" head instead of re-gating each PR after every restack, then merge them in order.
#   1. each PR (in the given order) must be OPEN, not a draft, and its head must be the head its RDD acknowledged
#   2. a LOCAL branch train/<ts> (a dedicated worktree, never pushed) is built from the base with `git merge --no-ff`
#      per PR head; a conflict drops that PR (typed `train-conflict`), the rest continue; no auto-resolution
#   3. ONE gate (kit-gate.sh) runs on the train head
#   4. green: per PR, in order, kit-wait-merge.sh (CI wait + merge-gate --merge, run in a worktree AT that PR's head,
#      so merge-gate's own RDD check covers the exact head). The first PR that does not merge stops the train; the
#      rest are reported pending. Red: nothing is merged.
# RDD stays per PR and per head: the train never replaces it. Merging a PR whose head moved after its RDD is refused
# twice: here (head pin) and by merge-gate (review_due / head_mismatch).
#
# Options:
#   --rdd-ok PR=SHA   (repeatable, REQUIRED for every PR) the head sha (7+ hex, prefix ok) the PR's RDD acknowledged.
#                     The pin is explicit input, never inferred: a PR without a pin is refused `rdd-unconfirmed`, a pin
#                     that is not the PR's current head is refused `rdd-head-mismatch`.
#   --pr-cwd PR=DIR   (repeatable) the worktree where PR's RDD ran. RDD authority is bound to the WORKTREE where the review
#                     ran (stored in the shared git dir, matched by a worktree identity), not just to the head, so
#                     merge-gate run from any other worktree at the same head refuses `review_due`. With --pr-cwd the
#                     merge (kit-wait-merge / merge-gate) runs in DIR, which stays in place. DIR must be a worktree of
#                     the repo whose HEAD is the pinned head, else the PR is refused `pr-cwd-mismatch`. A PR WITHOUT
#                     --pr-cwd is merged from the train's own detached worktree at its head, where merge-gate will
#                     likely refuse review_due (the train then stops there; the PRs after it stay pending).
#   --repo DIR       the kit checkout (default: the current directory); its sibling `<repo>-worktrees/` holds the train
#                     worktrees (never /tmp)
#   --base-ref REF    the train base and merge-gate base (default origin/main); the remote is the part before `/`
#   --state-dir DIR   receipt, gate log and gate lock; default ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/pipeline;
#                     refused when it resolves (symlinks included) inside the repo
#   --gate-cmd CMD    run CMD (bash -c, inside the train worktree) as the gate instead of the default full gate
#   --serial          the default full gate without -j (CLAUDE.md section 5 reference); not with --gate-cmd
#   --bisect          on a red gate, gate prefixes of the batch (binary search) to name the first PR whose inclusion
#                     turns the gate red. The base is ASSUMED green (never gated); the culprit may be an interaction
#   --dry-run         print the plan (`kit-merge-train: plan: ...`); run no git/gh, create nothing
# Environment: KIT_RETRY_SLEEP, and for kit-wait-merge.sh KIT_POLL_SLEEP, KIT_POLL_MAX, KIT_MERGE_SLEEP,
# KIT_MERGE_TRIES, KIT_MERGE_GATE.
#
# Receipt <state-dir>/train-<ts>.json: state, base_sha, train_sha, gate {rc, log, cmd}, per-PR {pr, head, status
# (merged|pending|dropped|refused|culprit), reason}, culprit. Written on every exit after the first fetch.
#
# Typed exit states (last line `kit-merge-train: <state>: ...`; registered in reason-codes.d/kit-merge-train.md):
#   merged            0   every requested PR merged
#   usage             2   bad arguments, or a state dir inside the repo
#   degraded          3   git, gh, jq or flock missing
#   ci-failed        17   (from kit-wait-merge) a CI check failed for the PR that stopped the train
#   merge-degraded   18   (from kit-wait-merge) merge-gate stayed degraded
#   not-merged       19   (from kit-wait-merge) merge-gate refused / PR not MERGED; later PRs pending
#   fetch-failed     21   git fetch still failing after 3 tries
#   gate-lock-timeout 22  the gate lock was not obtained in time (not a gate failure)
#   train-gate-failed 26  the combined gate was red; nothing merged (--bisect names the culprit)
#   train-partial    27   everything that stayed in the train merged, but PRs were refused or dropped (conflict)
#   train-empty      28   no PR survived the checks and the merges; nothing gated or merged
#   train-error      29   an unexpected git/worktree/gate failure (not a conflict), or INT/TERM (`interrupted`)
#   base-moved       30   the base moved during the gate; checked before the first merge; nothing merged
#   main-raced       31   after a merge, <base>^ is not the previous tip (another commit landed); train stopped
#   tree-mismatch    32   <base>^{tree} differs from the train tree (or the base+merged-prefix tree when it stopped early)
#   merged-out-of-band 33 (from kit-wait-merge --expect-head) the PR is MERGED at a head other than the gated one
# Per-PR refusals also include `base-not-<branch>` (the PR does not target the base branch; stacked PRs are not trained).
# A lock timeout while bisecting keeps the red full gate: train-gate-failed with `bisect-incomplete: gate-lock-timeout`.
set -u
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
# shellcheck disable=SC2034 # read by kit-maint-common.sh
KIT_TOOL=kit-merge-train
# shellcheck source=kit-maint-common.sh
. "$_RSDD_SELF/kit-maint-common.sh" || { echo "kit-merge-train: degraded: kit-maint-common.sh unavailable" >&2; exit 3; }

repo=. base=origin/main state='' gate_cmd='' serial=0 bisect=0 dry_run=0
declare -A pin=() pcwd=()
prs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rdd-ok) [ $# -ge 2 ] || kit_fail 2 usage "--rdd-ok needs PR=SHA"; k="${2%%=*}"; v="${2#*=}"
      case "$k" in ''|*[!0-9]*) kit_fail 2 usage "--rdd-ok PR must be a number: $2" ;; esac
      case "$v" in ''|*[!0-9a-fA-F]*) kit_fail 2 usage "--rdd-ok SHA must be hex: $2" ;; esac
      [ "${#v}" -ge 7 ] && [ "$k=$v" = "$2" ] || kit_fail 2 usage "--rdd-ok wants PR=SHA with 7+ hex chars: $2"
      pin[$k]="$v"; shift 2 ;;
    --pr-cwd) [ $# -ge 2 ] || kit_fail 2 usage "--pr-cwd needs PR=DIR"; k="${2%%=*}"; v="${2#*=}"
      case "$k" in ''|*[!0-9]*) kit_fail 2 usage "--pr-cwd PR must be a number: $2" ;; esac
      [ -n "$v" ] && [ "$k=$v" = "$2" ] || kit_fail 2 usage "--pr-cwd wants PR=DIR: $2"
      pcwd[$k]="$v"; shift 2 ;;
    --repo) [ $# -ge 2 ] || kit_fail 2 usage "--repo needs a value"; repo="$2"; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || kit_fail 2 usage "--base-ref needs a value"; base="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || kit_fail 2 usage "--state-dir needs a value"; state="$2"; shift 2 ;;
    --gate-cmd) [ $# -ge 2 ] || kit_fail 2 usage "--gate-cmd needs a value"; gate_cmd="$2"; shift 2 ;;
    --serial) serial=1; shift ;;
    --bisect) bisect=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) awk 'NR > 1 && /^[^#]/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) kit_fail 2 usage "unknown option $1" ;;
    *) break ;;
  esac
done
prs=("$@")
[ "${#prs[@]}" -ge 1 ] || kit_fail 2 usage "kit-merge-train.sh [options] <pr> [<pr>...]"
for p in "${prs[@]}"; do
  case "$p" in ''|*[!0-9]*) kit_fail 2 usage "pr must be a number: $p" ;; esac
done
[ "$(printf '%s\n' "${prs[@]}" | sort | uniq -d | wc -l)" -eq 0 ] || kit_fail 2 usage "a PR is listed twice"
for k in "${!pcwd[@]}"; do
  case " ${prs[*]} " in *" $k "*) ;; *) kit_fail 2 usage "--pr-cwd names #$k, which is not in the batch" ;; esac
done
[ "$serial" -eq 0 ] || [ -z "$gate_cmd" ] || kit_fail 2 usage "--serial cannot be combined with --gate-cmd"
case "$base" in */*) remote="${base%%/*}" ;; *) kit_fail 2 usage "--base-ref must be <remote>/<branch>: $base" ;; esac
[ -d "$repo" ] || kit_fail 2 usage "repo is not a directory: $repo"
repo="$(CDPATH='' cd -- "$repo" && pwd -P)" || kit_fail 2 usage "cannot resolve --repo"
[ -n "$state" ] || state="$(kit_state_dir)"
state="$(kit_phys_path "$state")" || kit_fail 2 usage "cannot resolve --state-dir"
case "$state/" in "$repo"/*) kit_fail 2 usage "--state-dir $state is inside the repo; state never lives in the repo" ;; esac
wtroot="$(dirname -- "$repo")/$(basename -- "$repo")-worktrees"

if [ "$dry_run" = 1 ]; then
  kit_say "plan: PRs ${prs[*]} in order onto $base; one gate (${gate_cmd:-default full gate}$([ "$serial" = 1 ] && echo ', serial')); bisect=$bisect"
  kit_say "plan: train worktree under $wtroot, state dir $state; each PR needs --rdd-ok; nothing was run"
  exit 0
fi

kit_probe_deps git gh jq flock || exit 3
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || kit_fail 2 usage "not a git checkout: $repo"
mkdir -p "$state" || kit_fail 2 usage "cannot create state dir $state"
ts="$(date +%Y%m%d-%H%M%S)-$$"
receipt="$state/train-$ts.json"
wt="$wtroot/train-$ts" branch="train/$ts"
declare -A p_head=() p_status=() p_reason=()
base_sha='' train_sha='' gate_rc='' gate_log='' culprit='' started=0
made_wts=()

write_receipt() { # $1 = final state
  local rows='' p
  for p in "${prs[@]}"; do
    rows+="$p"$'\t'"${p_head[$p]:-}"$'\t'"${p_status[$p]:-pending}"$'\t'"${p_reason[$p]:-}"$'\n'
  done
  printf '%s' "$rows" | jq -Rn --arg state "$1" --arg base "$base_sha" --arg train "$train_sha" --arg grc "$gate_rc" \
    --arg glog "$gate_log" --arg gcmd "${gate_cmd:-default}" --arg culprit "$culprit" --arg branch "$branch" '
    {state: $state, base_sha: $base, train_branch: $branch, train_sha: $train,
     gate: {rc: (if $grc == "" then null else ($grc | tonumber) end), log: $glog, cmd: $gcmd},
     culprit: (if $culprit == "" then null else ($culprit | tonumber) end),
     prs: [inputs | select(length > 0) | split("\t") | {pr: (.[0] | tonumber), head: .[1], status: .[2], reason: .[3]}]}' \
    > "$receipt" 2>/dev/null || kit_say "degraded: could not write the receipt $receipt"
}
cleanup() {
  local w p
  for w in ${made_wts[@]+"${made_wts[@]}"}; do git -C "$repo" worktree remove --force "$w" >/dev/null 2>&1; done
  [ "$started" = 0 ] || git -C "$repo" branch -D "$branch" >/dev/null 2>&1
  for p in "${prs[@]}"; do git -C "$repo" update-ref -d "refs/train/$ts/$p" >/dev/null 2>&1; done
  git -C "$repo" worktree prune >/dev/null 2>&1
  return 0
}
finish() { # CODE STATE MSG
  trap '' INT TERM
  write_receipt "$2"; cleanup
  kit_say "receipt=$receipt"
  kit_fail "$1" "$2" "${3:-}"
}
trap 'finish 29 train-error "interrupted"' INT TERM

# --pr-cwd PR=DIR: DIR must be a worktree of THIS repo (same common git dir) whose HEAD is the pinned head; it is
# resolved to its physical path. RDD authority is bound to the worktree where the review ran (kit issue #2213).
pr_cwd_ok() { # PR HEAD_SHA
  local d="${pcwd[$1]}" a b
  [ -d "$d" ] || return 1
  a="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  b="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$a" ] && [ "$a" = "$b" ] || return 1
  [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$2" ] || return 1
  pcwd[$1]="$(CDPATH='' cd -- "$d" && pwd -P)"
}

kit_retry 3 git -C "$repo" fetch -q "$remote" || finish 21 fetch-failed "git fetch $remote still failing"
base_sha="$(git -C "$repo" rev-parse "$base^{commit}" 2>/dev/null)" || finish 29 train-error "base ref $base does not resolve"
base_branch="${base#*/}"

# 1. per-PR checks: open, not draft, RDD head pin, head fetched and equal to what gh reports
keep=()
for p in "${prs[@]}"; do
  info="$(kit_retry 3 gh pr view "$p" --json state,isDraft,headRefOid,baseRefName 2>/dev/null)" && [ -n "$info" ] || { p_status[$p]=refused; p_reason[$p]=gh-view-failed; kit_say "train-refused #$p: gh pr view failed"; continue; }
  oid="$(jq -r '.headRefOid // empty' <<<"$info" 2>/dev/null)"; p_head[$p]="$oid"
  why=''
  if [ "$(jq -r '.state // empty' <<<"$info" 2>/dev/null)" != OPEN ]; then why=not-open
  elif [ "$(jq -r '.isDraft' <<<"$info" 2>/dev/null)" != false ]; then why=draft
  elif [ "$(jq -r '.baseRefName // empty' <<<"$info" 2>/dev/null)" != "$base_branch" ]; then why="base-not-$base_branch"
  elif [ -z "$oid" ]; then why=no-head
  elif [ -z "${pin[$p]:-}" ]; then why=rdd-unconfirmed
  elif lo_oid="${oid,,}" && [ "${lo_oid#"${pin[$p],,}"}" = "$lo_oid" ]; then why=rdd-head-mismatch
  elif [ -n "${pcwd[$p]:-}" ] && ! pr_cwd_ok "$p" "$oid"; then why=pr-cwd-mismatch
  elif ! kit_retry 3 git -C "$repo" fetch -q "$remote" "+refs/pull/$p/head:refs/train/$ts/$p" 2>/dev/null \
       || [ "$(git -C "$repo" rev-parse "refs/train/$ts/$p" 2>/dev/null)" != "$oid" ]; then why=head-moved
  fi
  if [ -n "$why" ]; then p_status[$p]=refused; p_reason[$p]=$why; kit_say "train-refused #$p: $why"; continue; fi
  keep+=("$p")
done
[ "${#keep[@]}" -gt 0 ] || finish 28 train-empty "no PR passed the checks"

# 2. the local train
mkdir -p "$wtroot" || finish 29 train-error "cannot create $wtroot"
git -C "$repo" worktree add -q -b "$branch" "$wt" "$base_sha" || finish 29 train-error "cannot create the train worktree $wt"
started=1; made_wts+=("$wt")
merged=()
for p in "${keep[@]}"; do
  if git -C "$wt" merge -q --no-ff -m "train: merge #$p" "${p_head[$p]}" >/dev/null 2>&1; then
    merged+=("$p")
  elif [ -n "$(git -C "$wt" ls-files -u)" ]; then
    git -C "$wt" merge --abort >/dev/null 2>&1
    p_status[$p]=dropped; p_reason[$p]=train-conflict; kit_say "train-conflict #$p: dropped from the batch"
  else
    git -C "$wt" merge --abort >/dev/null 2>&1
    finish 29 train-error "merging #$p failed without a conflict"
  fi
done
[ "${#merged[@]}" -gt 0 ] || finish 28 train-empty "every PR conflicted"
train_sha="$(git -C "$wt" rev-parse HEAD)"

# 3. ONE gate
gate_args=(--state-dir "$state")
[ -z "$gate_cmd" ] || gate_args+=(--cmd "$gate_cmd")
[ "$serial" = 0 ] || gate_args+=(--serial)
in_bisect=0
run_gate() { # LABEL -> sets gate_rc/gate_log, returns 0 green, 16 red, 22 lock timeout (bisect only; else exits)
  local rc
  gate_log="$state/gate-$1.log"
  bash "$_RSDD_SELF/kit-gate.sh" "${gate_args[@]}" "$wt" "$1"; rc=$?
  case "$rc" in
    0) gate_rc=0 ;;
    16) gate_rc=$(sed -n 's/^gate rc=//p' "$gate_log" 2>/dev/null | tail -1); gate_rc="${gate_rc:-1}" ;;
    22) if [ "$in_bisect" = 1 ]; then return 22; fi; finish 22 gate-lock-timeout "another gate holds the lock" ;;
    *) finish 29 train-error "kit-gate.sh exited $rc" ;;
  esac
  return "$rc"
}
if ! run_gate "train-$ts"; then
  incomplete=''
  if [ "$bisect" = 1 ]; then
    final_gate_rc="$gate_rc" final_gate_log="$gate_log" in_bisect=1
    lo=0 hi=${#merged[@]}
    while [ $((hi - lo)) -gt 1 ]; do
      mid=$(((lo + hi) / 2))
      git -C "$wt" reset -q --hard "$base_sha" || finish 29 train-error "bisect reset failed"
      for ((i = 0; i < mid; i++)); do
        git -C "$wt" merge -q --no-ff -m "train: merge #${merged[$i]}" "${p_head[${merged[$i]}]}" >/dev/null 2>&1 \
          || finish 29 train-error "bisect re-merge of #${merged[$i]} failed"
      done
      kit_say "bisect: gating the first $mid of ${#merged[@]} PRs"
      run_gate "train-$ts-bisect-$mid"; r=$?
      case "$r" in 0) lo=$mid ;; 22) incomplete=gate-lock-timeout; break ;; *) hi=$mid ;; esac
    done
    in_bisect=0
    # the FULL gate's verdict stays the receipt's gate result, whatever the bisect runs did
    gate_rc="$final_gate_rc" gate_log="$final_gate_log"
    if [ -z "$incomplete" ]; then
      culprit="${merged[$((hi - 1))]}"; p_status[$culprit]=culprit; p_reason[$culprit]=first-red-prefix
      kit_say "bisect: first red prefix ends at #$culprit (the base is assumed green; may be an interaction)"
    fi
  fi
  finish 26 train-gate-failed "the combined gate was red${culprit:+; culprit #$culprit}${incomplete:+; bisect-incomplete: $incomplete}; nothing merged (log $gate_log)"
fi

# 4. main must still be where the train was built, and every squash must land directly on the previous tip
kit_retry 3 git -C "$repo" fetch -q "$remote" || finish 21 fetch-failed "git fetch $remote failing after the gate"
cur="$(git -C "$repo" rev-parse "$base^{commit}" 2>/dev/null)"
[ "$cur" = "$base_sha" ] || finish 30 base-moved "$base moved from $base_sha to ${cur:-unknown} during the gate; nothing merged, re-run"
exp_tip="$base_sha"

verify_tree() { # the tree on main must equal the tree of base + the PRs actually merged
  local want got p
  [ "${#merged_ok[@]}" -gt 0 ] || return 0
  if [ "${#merged_ok[@]}" -eq "${#merged[@]}" ]; then
    want="$(git -C "$wt" rev-parse "$train_sha^{tree}")"
  else
    git -C "$wt" reset -q --hard "$base_sha" || finish 29 train-error "prefix tree reset failed"
    for p in "${merged_ok[@]}"; do
      git -C "$wt" merge -q --no-ff -m "train: merge #$p" "${p_head[$p]}" >/dev/null 2>&1 || finish 29 train-error "prefix tree re-merge of #$p failed"
    done
    want="$(git -C "$wt" rev-parse 'HEAD^{tree}')"
  fi
  got="$(git -C "$repo" rev-parse "$base^{tree}" 2>/dev/null)"
  [ "$got" = "$want" ] || finish 32 tree-mismatch "$base tree $got differs from the train tree $want for the merged PRs (${merged_ok[*]}); inspect main"
}

# 5. merge in order, in a worktree at each PR's own head
stopped='' stop_rc=0 merged_ok=()
for p in "${merged[@]}"; do
  if [ -n "$stopped" ]; then p_status[$p]=pending; p_reason[$p]="after #$stopped"; continue; fi
  own_wt=0
  if [ -n "${pcwd[$p]:-}" ]; then
    pw="${pcwd[$p]}"   # the worktree where this PR's RDD ran: left in place, never removed
  else
    pw="$wtroot/train-$ts-pr$p" own_wt=1
    if ! git -C "$repo" worktree add -q --detach "$pw" "${p_head[$p]}"; then
      stopped=$p; stop_rc=29; p_status[$p]=pending; p_reason[$p]=worktree-failed; continue
    fi
    made_wts+=("$pw")
  fi
  bash "$_RSDD_SELF/kit-wait-merge.sh" --base-ref "$base" --expect-head "${p_head[$p]}" "$pw" "$p"; mrc=$?
  [ "$own_wt" = 0 ] || git -C "$repo" worktree remove --force "$pw" >/dev/null 2>&1
  case "$mrc" in
    0)
      p_status[$p]=merged; merged_ok+=("$p")
      if ! kit_retry 3 git -C "$repo" fetch -q "$remote"; then
        stopped=$p; stop_rc=21; p_reason[$p]="fetch after the merge failed"
      else
        cur="$(git -C "$repo" rev-parse "$base^{commit}" 2>/dev/null)"
        if [ "$(git -C "$repo" rev-parse "$base^" 2>/dev/null)" != "$exp_tip" ]; then
          stopped=$p; stop_rc=31; p_reason[$p]="main-raced: $base^ is not the expected tip $exp_tip"
        else
          exp_tip="$cur"
        fi
      fi ;;
    33) stopped=$p; stop_rc=33; p_status[$p]=out-of-band; p_reason[$p]="MERGED with a head other than the gated ${p_head[$p]}" ;;
    *) stopped=$p; stop_rc=$mrc; p_status[$p]=pending; p_reason[$p]="stopped: kit-wait-merge rc=$mrc" ;;
  esac
done
if [ -n "$stopped" ]; then
  case "$stop_rc" in
    17) st=ci-failed ;;
    18) st=merge-degraded ;;
    21) st=fetch-failed ;;
    29) st=train-error ;;
    31) st=main-raced ;;
    33) st='merged-out-of-band' ;;
    *) st=not-merged; stop_rc=19 ;;
  esac
  case "$st" in not-merged|ci-failed|merge-degraded) verify_tree ;; esac
  finish "$stop_rc" "$st" "#$stopped stopped the train; merged so far: ${merged_ok[*]:-none}; the PRs after it are pending"
fi
verify_tree
for p in "${prs[@]}"; do
  if [ "${p_status[$p]:-}" != merged ]; then
    finish 27 train-partial "merged: ${merged_ok[*]}; refused or dropped: see the receipt"
  fi
done
finish 0 merged "all ${#merged_ok[@]} PRs merged after one gate on train $train_sha"
