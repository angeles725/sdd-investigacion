#!/usr/bin/env bash
# kit-merge-train.test.sh — kit issue #2213: maint/kit-merge-train.sh (one gate on a combined train head, then
# merge the batch in order).
#
# Every case builds REAL tiny git repos in $TMPDIR (origin = a bare repo; each PR head is pushed to
# refs/pull/N/head) and runs the real kit-merge-train.sh, kit-gate.sh and kit-wait-merge.sh against PATH shims for
# gh and merge-gate.sh plus a gate command that records the files present in the train worktree. The one ordered
# calls.log shows `gh ...`, `GATE <head> <files>` and `MERGE <pr> head=<sha>` in the order they happened.
# Nothing reaches the network, a real remote or gentle-ai. Typed exits are asserted by exit code AND state line.
#
# Usage: kit-merge-train.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
#        kit-merge-train.test.sh --scenario NAME STAGED_SUT_PATH   (internal: one case against a staged copy)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SELF="$HERE/kit-merge-train.test.sh"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
MAINT="$TB/maint"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_sed mutant_tooth || exit 2
for f in kit-merge-train.sh kit-gate.sh kit-wait-merge.sh kit-maint-common.sh; do
  [ -f "$MAINT/$f" ] || { echo "FATAL: SUT not found: $MAINT/$f" >&2; exit 2; }
done
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
STAGE="$MAINT"
OUT=''; RC=0; CALLS=''; CASE=''; SUMMARY=''

GATE='echo "GATE $(git rev-parse HEAD) $(ls pr-*.txt 2>/dev/null | tr "\n" " ")" >> "$CASE/calls.log"; [ ! -e bad.txt ]'

# mk_case: origin (bare) + repo clone with base.txt/shared.txt on main, shims in $CASE/bin
mk_case() {
  CASE="$(mktemp -d "$TMP/case.XXXXXX")" || return 2
  mkdir -p "$CASE/bin" "$CASE/state"
  local t p
  for t in bash env cat grep sed awk sleep date mkdir rm cut tail head dirname readlink basename mktemp tr sort wc touch ls \
           uniq tee ln find python3 cp mv chmod true false sh git jq flock timeout; do
    p="$(command -v "$t")" && [ -n "$p" ] && ln -sf "$p" "$CASE/bin/$t"
  done
  cat > "$CASE/bin/gh" <<'E'
#!/usr/bin/env bash
echo "gh $*" >> "$CASE/calls.log"
case "$*" in
  "pr view "*"--json state,isDraft,headRefOid,baseRefName") cat "$CASE/pr-$3.json" ;;
  "pr view "*"--json state -q .state") if [ -e "$CASE/merged-$3" ]; then echo MERGED; else echo OPEN; fi ;;
  "pr view "*"--json headRefOid,mergeCommit -q "*)
    if [ -e "$CASE/oob-$3" ]; then echo "$(cat "$CASE/oob-$3") mc$3"; else echo "$(cat "$CASE/head-$3") mc$3"; fi ;;
  "pr checks "*) if [ -e "$CASE/ci-fail-$3" ]; then echo "lint fail"; exit 1; fi; echo "all checks pass"; exit 0 ;;
  *) exit 1 ;;
esac
E
  # merge-gate shim: a real squash onto origin/main (via the $CASE/sq clone) so main actually moves
  cat > "$CASE/merge-gate.sh" <<'E'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --cwd) cwd="$2"; shift 2 ;; --merge) pr="$2"; shift 2 ;; *) shift ;; esac; done
echo "MERGE $pr head=$(git -C "$cwd" rev-parse HEAD)" >> "$CASE/calls.log"
if [ -e "$CASE/mg-degrade-$pr" ]; then echo "merge-gate: degraded: simulated"; exit 3; fi
if [ -e "$CASE/mg-fail-$pr" ]; then echo "merge-gate: refuse: review_due (high_risk)"; exit 1; fi
sq="$CASE/sq"
git -C "$sq" fetch -q origin "refs/pull/$pr/head" && git -C "$sq" checkout -q -B main origin/main || exit 1
[ -e "$CASE/mg-race-$pr" ] && bash "$CASE/push-extra.sh" "race-$pr"
git -C "$sq" fetch -q origin && git -C "$sq" checkout -q -B main origin/main
git -C "$sq" merge --squash "$(cat "$CASE/head-$pr")" >/dev/null || exit 1
[ -e "$CASE/mg-tweak-$pr" ] && echo tweak > "$sq/tweak.txt"
git -C "$sq" add -A && git -C "$sq" commit -q -m "squash #$pr" && git -C "$sq" push -q origin HEAD:main || exit 1
touch "$CASE/merged-$pr"; echo "merge-gate: allow (merged)"
E
  cat > "$CASE/push-extra.sh" <<'E'
#!/usr/bin/env bash
# another actor lands a commit on origin/main
sq="$CASE/sq"
git -C "$sq" fetch -q origin && git -C "$sq" checkout -q -B main origin/main
echo "$1" > "$sq/extra-$1.txt"; git -C "$sq" add -A && git -C "$sq" commit -q -m "extra $1" && git -C "$sq" push -q origin HEAD:main
E
  chmod +x "$CASE/bin/gh" "$CASE/merge-gate.sh" "$CASE/push-extra.sh"
  : > "$CASE/calls.log"
  git init -q --bare -b main "$CASE/origin.git" || return 2
  git init -q -b main "$CASE/repo" || return 2
  git -C "$CASE/repo" config user.name t; git -C "$CASE/repo" config user.email t@example.com
  git -C "$CASE/repo" remote add origin "$CASE/origin.git"
  printf 'base\n' > "$CASE/repo/base.txt"; printf 'base\n' > "$CASE/repo/shared.txt"
  git -C "$CASE/repo" add . && git -C "$CASE/repo" commit -q -m base && git -C "$CASE/repo" push -q origin main || return 2
  git -C "$CASE/repo" fetch -q origin
  git clone -q "$CASE/origin.git" "$CASE/sq" || return 2
  git -C "$CASE/sq" config user.name t; git -C "$CASE/sq" config user.email t@example.com
}
# mkpr N [FILE [CONTENT]] — a PR head branched from the CURRENT origin/main, pushed to refs/pull/N/head
mkpr() {
  local n="$1" f="${2:-pr-$1.txt}" c="${3:-$1}" sha
  git -C "$CASE/repo" checkout -q -B "pr$n" origin/main
  printf "%s\n" "$c" > "$CASE/repo/$f"; printf "%s\n" "$n" > "$CASE/repo/pr-$n.txt"
  git -C "$CASE/repo" add . && git -C "$CASE/repo" commit -q -m "pr $n"
  git -C "$CASE/repo" push -q origin "HEAD:refs/pull/$n/head"
  sha="$(git -C "$CASE/repo" rev-parse HEAD)"; echo "$sha" > "$CASE/head-$n"
  printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","baseRefName":"main"}\n' "$sha" > "$CASE/pr-$n.json"
  git -C "$CASE/repo" checkout -q main
}
pins() { local n; for n in "$@"; do printf -- '--rdd-ok\n%s=%s\n' "$n" "$(cut -c1-12 "$CASE/head-$n")"; done; }
advance_main() { # a new commit on origin/main touching shared.txt
  git -C "$CASE/repo" checkout -q main; printf 'Z\n' > "$CASE/repo/shared.txt"
  git -C "$CASE/repo" commit -q -am "main moves" && git -C "$CASE/repo" push -q origin main && git -C "$CASE/repo" fetch -q origin
}

# run_train NAME — builds the case, runs STAGE/kit-merge-train.sh, fills OUT RC CALLS SUMMARY
run_train() {
  local name="$1" extra=() prs=() pinned=()
  mk_case || return 2
  case "$name" in
    happy) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3) ;;
    conflict-mid) mkpr 1 shared.txt A; mkpr 2 shared.txt B; mkpr 3; prs=(1 2 3) ;;
    conflict-last) mkpr 1; mkpr 2 shared.txt A; mkpr 3 shared.txt B; prs=(1 2 3) ;;
    conflict-first) mkpr 1 shared.txt A; mkpr 2; advance_main; prs=(1 2) ;;
    conflict-all) mkpr 1 shared.txt A; advance_main; prs=(1) ;;
    rdd-mismatch) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); pinned=(1 3) ;;
    rdd-missing) mkpr 1; mkpr 2; prs=(1 2); pinned=(1) ;;
    notopen|draft) mkpr 1; mkpr 2; prs=(1 2) ;;
    head-moved) mkpr 1; mkpr 2; prs=(1 2) ;;
    gate-red) mkpr 1; mkpr 2 bad.txt; mkpr 3; prs=(1 2 3) ;;
    bisect-mid) mkpr 1; mkpr 2; mkpr 3 bad.txt; mkpr 4; prs=(1 2 3 4); extra=(--bisect) ;;
    bisect-first) mkpr 1 bad.txt; mkpr 2; mkpr 3; mkpr 4; prs=(1 2 3 4); extra=(--bisect) ;;
    bisect-last) mkpr 1; mkpr 2; mkpr 3; mkpr 4 bad.txt; prs=(1 2 3 4); extra=(--bisect) ;;
    bisect-single) mkpr 1 bad.txt; prs=(1); extra=(--bisect) ;;
    mgfail-first) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-fail-1" ;;
    mgfail-mid) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-fail-2" ;;
    mgfail-last) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-fail-3" ;;
    cifail-mid) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/ci-fail-2" ;;
    mgdegrade) mkpr 1; mkpr 2; prs=(1 2); touch "$CASE/mg-degrade-1" ;;
    base-moved|base-moved-gate) mkpr 1; mkpr 2; prs=(1 2) ;;
    main-raced) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-race-2" ;;
    tree-mismatch) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-tweak-3" ;;
    tree-mismatch-prefix) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); touch "$CASE/mg-tweak-1" "$CASE/mg-fail-2" ;;
    stacked) mkpr 1; mkpr 2; prs=(1 2) ;;
    oob) mkpr 1; mkpr 2; mkpr 3; prs=(1 2 3); echo deadbeefdeadbeef > "$CASE/oob-2" ;;
    term) mkpr 1; mkpr 2; prs=(1 2) ;;
    bisect-locktimeout) mkpr 1; mkpr 2 bad.txt; mkpr 3; prs=(1 2 3); extra=(--bisect) ;;
    merge-error) mkpr 1; mkpr 2; prs=(1 2); printf '#!/bin/sh\nexit 1\n' > "$CASE/repo/.git/hooks/pre-merge-commit"; chmod +x "$CASE/repo/.git/hooks/pre-merge-commit" ;;
    dry) mkpr 1; mkpr 2; prs=(1 2); extra=(--dry-run) ;;
    nojq|nogh|noflock) mkpr 1; prs=(1); rm -f "$CASE/bin/${name#no}" ;;
    nofetch) mkpr 1; prs=(1); rm -rf "$CASE/origin.git" ;;
    usage-none) ;;
    usage-nan) prs=(x1) ;;
    usage-dup) mkpr 1; prs=(1 1) ;;
    usage-state-in-repo) mkpr 1; prs=(1); extra=(--state-dir "$CASE/repo/state") ;;
    usage-serial-cmd) mkpr 1; prs=(1); extra=(--serial) ;;
    usage-badpin) mkpr 1; prs=(1); extra=(--rdd-ok "1=zz") ;;
  esac
  [ "${#pinned[@]}" -gt 0 ] || pinned=("${prs[@]}")
  local -a pinargs=()
  if [ "${#pinned[@]}" -gt 0 ] && [ -f "$CASE/head-${pinned[0]}" ]; then mapfile -t pinargs < <(pins "${pinned[@]}"); fi
  case "$name" in
    rdd-mismatch) pinargs=(--rdd-ok "1=$(cut -c1-12 "$CASE/head-1")" --rdd-ok "2=$(printf '%012d' 123)" --rdd-ok "3=$(cut -c1-12 "$CASE/head-3")") ;;
    notopen) sed -i 's/"OPEN"/"MERGED"/' "$CASE/pr-2.json" ;;
    draft) sed -i 's/"isDraft":false/"isDraft":true/' "$CASE/pr-2.json" ;;
    head-moved) sed -i 's/"headRefOid":"[0-9a-f]*"/"headRefOid":"'"$(git -C "$CASE/repo" rev-parse origin/main)"'"/' "$CASE/pr-2.json"
      pinargs=(--rdd-ok "1=$(cut -c1-12 "$CASE/head-1")" --rdd-ok "2=$(git -C "$CASE/repo" rev-parse origin/main | cut -c1-12)") ;;
  esac
  case "$name" in
    stacked) sed -i 's/"baseRefName":"main"/"baseRefName":"feat\/other"/' "$CASE/pr-2.json" ;;
  esac
  local g="$GATE"; local -a wrap=()
  case "$name" in
    base-moved-gate) g="bash \"\$CASE/push-extra.sh\" gate-race; $GATE" ;;
    term) g='sleep 30'; wrap=(timeout --preserve-status -s TERM 4) ;;
    bisect-locktimeout) g='[ -e "$CASE/ran" ] || { touch "$CASE/ran"; sleep 6 & }; '"$GATE" ;;
  esac
  local -a gate=(--gate-cmd "$g")
  [ "$name" = usage-state-in-repo ] || extra=(--state-dir "$CASE/state" "${extra[@]}")
  OUT="$(cd "$CASE" && env PATH="$CASE/bin" HOME="$CASE" CASE="$CASE" KIT_RETRY_SLEEP=0 KIT_POLL_SLEEP=0 KIT_MERGE_SLEEP=0 \
         KIT_MERGE_TRIES=1 KIT_GATE_LOCK_TIMEOUT=2 KIT_MERGE_GATE="$CASE/merge-gate.sh" \
         ${wrap[@]+"${wrap[@]}"} bash "$STAGE/kit-merge-train.sh" --repo "$CASE/repo" "${gate[@]}" "${extra[@]}" ${pinargs[@]+"${pinargs[@]}"} ${prs[@]+"${prs[@]}"} 2>&1)"
  RC=$?
  CALLS="$(cat "$CASE/calls.log")"
  local rcpt; rcpt="$(ls "$CASE"/state/train-*.json 2>/dev/null | head -1)"
  SUMMARY="receipt: $( [ -n "$rcpt" ] && jq -c '{state, culprit, gate_rc: .gate.rc, gate_log: (.gate.log | split("/") | last), prs: [.prs[] | "\(.pr)=\(.status)"]}' "$rcpt" || echo none )
remote-heads: $(git -C "$CASE/origin.git" for-each-ref --format='%(refname)' 'refs/heads/' | tr '\n' ' ')
local-branches: $(git -C "$CASE/repo" for-each-ref --format='%(refname:short)' 'refs/heads/train/*' | tr '\n' ' ')
worktrees-left: $(ls "$CASE/repo-worktrees" 2>/dev/null | tr '\n' ' ')
train-refs: $(git -C "$CASE/repo" for-each-ref --format='%(refname)' 'refs/train/' | tr '\n' ' ')"
}
nth_count() { grep -cE -- "$1" <<<"$CALLS"; }
merges() { grep '^MERGE' <<<"$CALLS" | awk '{print $2}' | tr '\n' ' '; }
rj() { jq -r "$1" "$CASE"/state/train-*.json 2>/dev/null; }

if [ "${1:-}" = "--scenario" ]; then
  STAGE="$(dirname "${3:?staged SUT path}")"
  run_train "${2:?scenario}"
  printf '%s\n--calls--\n%s\n--summary--\n%s\n' "$OUT" "$CALLS" "$SUMMARY"
  exit "$RC"
fi

echo "== kit-merge-train.test.sh =="

# ---- happy path: ONE gate, merges in order, each merge-gate run sits at that PR's own head ----
run_train happy
heads_ok=1; for n in 1 2 3; do grep -qxF "MERGE $n head=$(cat "$CASE/head-$n")" <<<"$CALLS" || heads_ok=0; done
if [ "$RC" = 0 ] && [[ "$OUT" == *'kit-merge-train: merged'* ]] && [ "$(nth_count '^GATE')" = 1 ] && [ "$(merges)" = '1 2 3 ' ]; then
  ok "happy: rc 0, exactly ONE gate call, merges in the given order (1 2 3)"
else no "happy rc=$RC gates=$(nth_count '^GATE') merges=[$(merges)] out=[$OUT]"; fi
[ "$heads_ok" = 1 ] && ok "happy: every merge-gate run is in a worktree AT that PR's own head" || no "happy: merge-gate head mismatch calls=[$CALLS]"
g="$(grep -n '^GATE' <<<"$CALLS" | head -1 | cut -d: -f1)"; m="$(grep -n '^MERGE' <<<"$CALLS" | head -1 | cut -d: -f1)"
[ -n "$g" ] && [ -n "$m" ] && [ "$g" -lt "$m" ] && ok "happy: the gate ran before the first merge" || no "happy: gate/merge order g=$g m=$m"
gline="$(grep '^GATE' <<<"$CALLS")"
if [[ "$gline" == *'pr-1.txt pr-2.txt pr-3.txt'* ]]; then ok "happy: the gate saw all three PRs combined in the train worktree"; else no "happy gate files [$gline]"; fi
if [ "$(rj .state)" = merged ] && [ "$(rj '.prs | map(.status) | join(",")')" = merged,merged,merged ] \
   && [ "$(rj .gate.rc)" = 0 ] && [ "$(rj .train_sha)" = "$(awk '/^GATE/ {print $2}' <<<"$CALLS")" ] \
   && [ "$(rj .base_sha)" = "$(git -C "$CASE/repo" rev-parse origin/main~3)" ] \
   && [[ "$(rj .gate.log)" == "$CASE"/state/gate-train-*.log ]] && [ -f "$(rj .gate.log)" ]; then
  ok "happy: the receipt names state, base/train sha (= the gated head), gate rc + existing log, all PRs merged"
else no "happy receipt: $(cat "$CASE"/state/train-*.json 2>/dev/null | tr -d '\n')"; fi
if [ "$(rj '.prs[0].head')" = "$(cat "$CASE/head-1")" ]; then ok "happy: the receipt records each PR head"; else no "receipt PR head [$(rj '.prs[0].head')]"; fi
if [[ "$SUMMARY" == *'remote-heads: refs/heads/main '* ]] && [[ "$SUMMARY" != *'refs/heads/train'* ]] && [[ "$SUMMARY" == *'local-branches: '$'\n'* ]]; then
  ok "happy: the train branch was never pushed and the local train branch is gone"
else no "happy branches: $SUMMARY"; fi
if [[ "$SUMMARY" == *'worktrees-left: '$'\n'* || "$SUMMARY" == *'worktrees-left: ' ]]; then ok "happy: every train worktree was removed"; else no "happy worktrees: $SUMMARY"; fi
if [[ "$SUMMARY" == *'train-refs: ' ]] && [[ "$CALLS" != *FETCH_HEAD* ]]; then ok "happy: PR heads were fetched into refs/train/<ts>/<pr> and those refs are removed afterwards"; else no "happy train refs: $SUMMARY"; fi
if [[ "$OUT" == *'merged: all 3 PRs merged after one gate'* ]] && [[ "$(rj '[.prs[] | select(.status == "merged")] | length')" = 3 ]]; then ok "happy: the final line counts only PRs actually merged"; else no "happy final line [$OUT]"; fi
if [[ "$CASE/repo-worktrees" == "$TMP"/* ]] && [ -d "$CASE/repo-worktrees" ]; then ok "worktrees live in the sibling <repo>-worktrees dir"; else no "worktree root missing"; fi

# ---- conflicts drop one PR, the rest continue (middle, last, first, all) ----
run_train conflict-mid
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-conflict #2'* ]] && [ "$(merges)" = '1 3 ' ] && [ "$(nth_count '^GATE')" = 1 ] \
   && [[ "$(grep '^GATE' <<<"$CALLS")" == *'pr-1.txt pr-3.txt'* ]] && [[ "$(grep '^GATE' <<<"$CALLS")" != *pr-2* ]] \
   && [ "$(rj '.prs | map(.status) | join(",")')" = merged,dropped,merged ]; then
  ok "conflict in the MIDDLE: #2 dropped (train-conflict), 1 and 3 gated once and merged, rc 27 train-partial"
else no "conflict-mid rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train conflict-last
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-conflict #3'* ]] && [ "$(merges)" = '1 2 ' ]; then ok "conflict in the LAST position: #3 dropped, 1 and 2 merged"
else no "conflict-last rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train conflict-first
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-conflict #1'* ]] && [ "$(merges)" = '2 ' ]; then ok "conflict in the FIRST position (vs a moved base): #1 dropped, #2 merged"
else no "conflict-first rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train conflict-all
if [ "$RC" = 28 ] && [[ "$OUT" == *'kit-merge-train: train-empty'* ]] && [ "$(nth_count '^GATE')" = 0 ] && [ -z "$(merges)" ]; then
  ok "a single PR that conflicts: train-empty (rc 28), no gate, no merge"
else no "conflict-all rc=$RC out=[$OUT]"; fi

# ---- RDD head pin: never inferred ----
run_train rdd-mismatch
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: rdd-head-mismatch'* ]] && [ "$(merges)" = '1 3 ' ]; then ok "a pin that is not the PR head is refused (rdd-head-mismatch); the others merge"
else no "rdd-mismatch rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train rdd-missing
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: rdd-unconfirmed'* ]] && [ "$(merges)" = '1 ' ]; then ok "a PR without an --rdd-ok pin is refused (rdd-unconfirmed), never assumed approved"
else no "rdd-missing rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train notopen
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: not-open'* ]] && [ "$(merges)" = '1 ' ]; then ok "a PR that is not OPEN is refused"; else no "notopen rc=$RC out=[$OUT]"; fi
run_train draft
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: draft'* ]] && [ "$(merges)" = '1 ' ]; then ok "a draft PR is refused"; else no "draft rc=$RC out=[$OUT]"; fi
run_train head-moved
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: head-moved'* ]] && [ "$(merges)" = '1 ' ]; then ok "a head that differs from refs/pull/N/head is refused (head-moved)"; else no "head-moved rc=$RC out=[$OUT]"; fi

# ---- red gate: nothing merged; bisect names the first red prefix (middle, first, last, single) ----
run_train gate-red
if [ "$RC" = 26 ] && [[ "$OUT" == *'kit-merge-train: train-gate-failed'* ]] && [ -z "$(merges)" ] && [ "$(nth_count '^GATE')" = 1 ] \
   && [ "$(rj .state)" = train-gate-failed ] && [ "$(rj .gate.rc)" = 1 ] && [ "$(rj .culprit)" = null ]; then
  ok "red gate: rc 26, nothing merged, one gate call, receipt gate rc=1, no culprit without --bisect"
else no "gate-red rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train bisect-mid
if [ "$RC" = 26 ] && [ "$(rj .culprit)" = 3 ] && [ "$(nth_count '^GATE')" = 3 ] && [ -z "$(merges)" ] && [[ "$OUT" == *'culprit #3'* ]] \
   && [ "$(rj '.prs | map(.status) | join(",")')" = pending,pending,culprit,pending ]; then
  ok "bisect finds the culprit in the middle (#3 of 4) in 3 gate runs; nothing merged"
else no "bisect-mid rc=$RC culprit=$(rj .culprit) gates=$(nth_count '^GATE') out=[$OUT]"; fi
run_train bisect-first
if [ "$RC" = 26 ] && [ "$(rj .culprit)" = 1 ]; then ok "bisect: the culprit in the FIRST position"; else no "bisect-first culprit=$(rj .culprit) out=[$OUT]"; fi
run_train bisect-last
if [ "$RC" = 26 ] && [ "$(rj .culprit)" = 4 ]; then ok "bisect: the culprit in the LAST position"; else no "bisect-last culprit=$(rj .culprit) out=[$OUT]"; fi
run_train bisect-single
if [ "$RC" = 26 ] && [ "$(rj .culprit)" = 1 ] && [ "$(nth_count '^GATE')" = 1 ]; then ok "bisect: a single-PR batch names it with no extra gate run"; else no "bisect-single culprit=$(rj .culprit) gates=$(nth_count '^GATE')"; fi

# ---- a merge failure stops the train; the rest are pending (first, middle, last) ----
run_train mgfail-mid
if [ "$RC" = 19 ] && [[ "$OUT" == *'kit-merge-train: not-merged'* ]] && [ "$(merges)" = '1 2 ' ] \
   && [ "$(rj '.prs | map(.status) | join(",")')" = merged,pending,pending ] && [ "$(nth_count '^GATE')" = 1 ]; then
  ok "merge failure in the middle: rc 19, #3 never attempted, receipt merged/pending/pending"
else no "mgfail-mid rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train mgfail-first
if [ "$RC" = 19 ] && [ "$(merges)" = '1 ' ] && [ "$(rj '.prs | map(.status) | join(",")')" = pending,pending,pending ]; then ok "merge failure on the FIRST PR: nothing merged, all pending"
else no "mgfail-first rc=$RC merges=[$(merges)]"; fi
run_train mgfail-last
if [ "$RC" = 19 ] && [ "$(merges)" = '1 2 3 ' ] && [ "$(rj '.prs | map(.status) | join(",")')" = merged,merged,pending ]; then ok "merge failure on the LAST PR: 1 and 2 merged, 3 pending"
else no "mgfail-last rc=$RC merges=[$(merges)]"; fi

# ---- B1: main may move during the gate, and the squashes must reproduce the train tree ----
run_train base-moved-gate
if [ "$RC" = 30 ] && [[ "$OUT" == *'kit-merge-train: base-moved'* ]] && [ -z "$(merges)" ] && [ "$(rj .state)" = base-moved ]; then
  ok "main moved during the gate: base-moved (rc 30), nothing merged, typed in the receipt"
else no "base-moved rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train main-raced
if [ "$RC" = 31 ] && [[ "$OUT" == *'kit-merge-train: main-raced'* ]] && [ "$(merges)" = '1 2 ' ] \
   && [ "$(rj '.prs | map(.status) | join(",")')" = merged,merged,pending ]; then
  ok "another commit landed before #2's squash: main-raced (rc 31), #2 recorded merged, #3 never attempted"
else no "main-raced rc=$RC merges=[$(merges)] summary=[$SUMMARY] out=[$OUT]"; fi
run_train tree-mismatch
if [ "$RC" = 32 ] && [[ "$OUT" == *'kit-merge-train: tree-mismatch'* ]] && [ "$(merges)" = '1 2 3 ' ] && [ "$(rj .state)" = tree-mismatch ]; then
  ok "a squash whose tree differs from the train tree: tree-mismatch (rc 32)"
else no "tree-mismatch rc=$RC out=[$OUT]"; fi
run_train tree-mismatch-prefix
if [ "$RC" = 32 ] && [[ "$OUT" == *'kit-merge-train: tree-mismatch'* ]] && [ "$(merges)" = '1 2 ' ]; then
  ok "a train that stopped early is compared against the base+merged-prefix tree (tree-mismatch on a tweaked squash)"
else no "tree-mismatch-prefix rc=$RC out=[$OUT]"; fi
# ---- B2: a stacked PR (base is not the train base branch) ----
run_train stacked
if [ "$RC" = 27 ] && [[ "$OUT" == *'train-refused #2: base-not-main'* ]] && [ "$(merges)" = '1 ' ]; then ok "a PR stacked on another branch is refused (base-not-main)"
else no "stacked rc=$RC out=[$OUT]"; fi
# ---- S1: MERGED with a head other than the gated one ----
run_train oob
if [ "$RC" = 33 ] && [[ "$OUT" == *'kit-merge-train: merged-out-of-band'* ]] && [ "$(merges)" = '1 2 ' ] \
   && [ "$(rj '.prs | map(.status) | join(",")')" = merged,out-of-band,pending ]; then
  ok "MERGED with a different head: merged-out-of-band (rc 33), never recorded as train-merged, #3 pending"
else no "oob rc=$RC merges=[$(merges)] summary=[$SUMMARY] out=[$OUT]"; fi
# ---- S2: INT/TERM cleans up and writes the receipt ----
run_train term
if [ "$RC" = 29 ] && [[ "$OUT" == *'train-error: interrupted'* ]] && [[ "$SUMMARY" == *'worktrees-left: '$'\n'* ]] \
   && [[ "$SUMMARY" == *'local-branches: '$'\n'* ]] && [[ "$SUMMARY" == *'train-refs: ' ]] && [ "$(rj .state)" = train-error ]; then
  ok "SIGTERM mid-gate: train-error interrupted (rc 29), worktrees, branch and train refs removed, receipt written"
else no "term rc=$RC summary=[$SUMMARY] out=[$OUT]"; fi
# ---- S4: a lock timeout during bisect does not hide the red full gate ----
run_train bisect-locktimeout
if [ "$RC" = 26 ] && [[ "$OUT" == *'kit-merge-train: train-gate-failed'* ]] && [[ "$OUT" == *'bisect-incomplete: gate-lock-timeout'* ]] \
   && [ "$(rj .gate.rc)" = 1 ] && [[ "$(rj .gate.log)" == */gate-train-2*[0-9].log ]] && [ "$(rj .culprit)" = null ]; then
  ok "gate lock timeout during bisect: train-gate-failed with bisect-incomplete, the full gate's rc and log kept"
else no "bisect-locktimeout rc=$RC gate=$(rj .gate.rc) log=$(rj .gate.log) out=[$OUT]"; fi
# ---- S3: stop-state mapping, the non-conflict merge failure ----
run_train cifail-mid
if [ "$RC" = 17 ] && [[ "$OUT" == *'kit-merge-train: ci-failed'* ]] && [ "$(merges)" = '1 ' ]; then ok "a CI failure stops the train as ci-failed (rc 17)"; else no "cifail-mid rc=$RC merges=[$(merges)] out=[$OUT]"; fi
run_train mgdegrade
if [ "$RC" = 18 ] && [[ "$OUT" == *'kit-merge-train: merge-degraded'* ]]; then ok "a degraded merge-gate stops the train as merge-degraded (rc 18)"; else no "mgdegrade rc=$RC out=[$OUT]"; fi
run_train merge-error
if [ "$RC" = 29 ] && [[ "$OUT" == *'kit-merge-train: train-error: merging #1 failed without a conflict'* ]] && [ -z "$(merges)" ]; then
  ok "a merge that fails WITHOUT unmerged paths is train-error (rc 29), not a conflict drop"
else no "merge-error rc=$RC out=[$OUT]"; fi

# ---- dry-run, degraded, fetch failure, usage ----
run_train dry
if [ "$RC" = 0 ] && [[ "$OUT" == *'kit-merge-train: plan:'* ]] && [ -z "$CALLS" ] && [ ! -e "$CASE/repo-worktrees" ] \
   && [ -z "$(ls "$CASE/state")" ] && [ -z "$(git -C "$CASE/repo" for-each-ref 'refs/heads/train/*')" ]; then
  ok "dry-run: prints the plan, calls no gh, creates no worktree, branch or state"
else no "dry rc=$RC calls=[$CALLS] out=[$OUT]"; fi
for d in jq gh flock; do
  run_train no$d
  if [ "$RC" = 3 ] && [[ "$OUT" == *"degraded: missing runtime dependency: $d"* ]]; then ok "degraded: missing $d -> rc 3, named"; else no "no$d rc=$RC out=[$OUT]"; fi
done
run_train nofetch
if [ "$RC" = 21 ] && [[ "$OUT" == *'kit-merge-train: fetch-failed'* ]]; then ok "an unreachable remote -> fetch-failed (rc 21)"; else no "nofetch rc=$RC out=[$OUT]"; fi
for u in usage-none usage-nan usage-dup usage-state-in-repo usage-serial-cmd usage-badpin; do
  run_train $u
  if [ "$RC" = 2 ] && [[ "$OUT" == *'kit-merge-train: usage'* ]] && [ ! -e "$CASE/repo-worktrees" ]; then ok "$u -> rc 2 usage, nothing created"; else no "$u rc=$RC out=[$OUT]"; fi
done

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: kit-merge-train mutation controls --"
n=0
# tooth LABEL FILE SED_EXPR GOOD_RC BAD_RC SCENARIO [mutant_tooth opts...]: stage a copy of maint/, mutate FILE there
# (mutant_sed refuses an empty, identical or syntax-broken mutant), run the scenario on the real and the staged tool.
tooth() {
  local label="$1" file="$2" expr="$3" g="$4" b="$5" sc="$6"; shift 6
  local st="$TMP/stage.$((n += 1))"
  mkdir -p "$st" && cp "$MAINT"/* "$st"/ && rm -f "$st/$file"
  if ! mutant_sed "$MAINT/$file" "$st/$file" "$expr"; then no "tooth $label: mutant refused"; return; fi
  chmod +x "$st"/*.sh "$st"/*.py
  if mutant_tooth "tooth $label" "$g" "$b" "$st/$file" --orig "$MAINT/$file" "$@" -- bash "$SELF" --scenario "$sc" @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
T=kit-merge-train.sh; C=kit-maint-common.sh
tooth "red gate ignored" $T 's/^if ! run_gate "train-\$ts"; then$/if false; then/' 26 0 gate-red --good-lacks '^MERGE' --bad-has '^MERGE 1'
tooth "RDD pin requirement dropped" $T 's/then why=rdd-unconfirmed/then why=/' 27 0 rdd-missing --good-lacks '^MERGE 2' --bad-has '^MERGE 2'
tooth "RDD head comparison dropped" $T 's/then why=rdd-head-mismatch/then why=; true/' 27 0 rdd-mismatch --good-lacks '^MERGE 2' --bad-has '^MERGE 2'
tooth "open-state check dropped" $T 's/then why=not-open/then why=/' 27 0 notopen --good-lacks '^MERGE 2' --bad-has '^MERGE 2'
tooth "draft check dropped" $T 's/then why=draft/then why=/' 27 0 draft --good-lacks '^MERGE 2' --bad-has '^MERGE 2'
tooth "merge conflict not aborted" $T 's/^    git -C "\$wt" merge --abort >\/dev\/null 2>&1$/    true/' 27 27 conflict-mid --good-has "^MERGE 3" --bad-lacks "^MERGE 3"
tooth "train branch pushed" $T 's/^started=1; made_wts+=("\$wt")$/started=1; made_wts+=("$wt"); git -C "$repo" push -q "$remote" "$branch"/' 0 0 happy --good-lacks 'refs/heads/train' --bad-has 'refs/heads/train'
tooth "worktrees not removed" $T 's/worktree remove --force "\$w"/worktree list/' 0 0 happy --good-lacks 'worktrees-left: train' --bad-has 'worktrees-left: train'
tooth "bisect direction inverted" $T 's/0) lo=\$mid ;;/0) hi=$mid ;;/;s/\*) hi=\$mid ;; esac/*) lo=$mid ;; esac/' 26 26 bisect-mid --good-has 'culprit #3' --bad-lacks 'culprit #3'
tooth "train does not stop at the first failure" $T 's/^  if \[ -n "\$stopped" \]; then p_status/  if false; then p_status/' 19 19 mgfail-mid --good-lacks '^MERGE 3' --bad-has '^MERGE 3'
tooth "dry-run guard removed" $T 's/^if \[ "\$dry_run" = 1 \]; then$/if false; then/' 0 0 dry --good-lacks '^gh ' --bad-has '^gh '
tooth "duplicate PR check removed" $T 's/^\[ "\$(printf .*uniq -d.*$/true/' 2 31 usage-dup --bad-lacks "kit-merge-train: usage"
W=kit-wait-merge.sh
tooth "head-moved check dropped" $T 's/then why=head-moved/then why=/' 27 33 head-moved --good-lacks "^MERGE 2" --bad-has "merged-out-of-band"
tooth "partial exit always 0" $T 's/finish 27 train-partial/finish 0 train-partial/' 27 0 conflict-mid --bad-has 'train-partial'
tooth "non-conflict merge failure treated as conflict" $T 's/^  elif \[ -n "\$(git -C "\$wt" ls-files -u)" \]; then$/  elif true; then/' 29 28 merge-error --bad-has 'train-empty'
tooth "ci-failed state mislabelled" $T 's/17) st=ci-failed ;;/17) st=not-merged ;;/' 17 17 cifail-mid --good-has 'kit-merge-train: ci-failed' --bad-lacks 'kit-merge-train: ci-failed'
tooth "merge-degraded state mislabelled" $T 's/18) st=merge-degraded ;;/18) st=other ;;/' 18 18 mgdegrade --good-has 'kit-merge-train: merge-degraded' --bad-lacks 'kit-merge-train: merge-degraded'
tooth "default stop state mislabelled" $T 's/\*) st=not-merged; stop_rc=19 ;;/*) st=other ;;/' 19 19 mgfail-mid --good-has 'kit-merge-train: not-merged' --bad-lacks 'kit-merge-train: not-merged'
tooth "base-moved check dropped" $T 's/^\[ "\$cur" = "\$base_sha" \] || finish 30/true || finish 30/' 30 31 base-moved-gate --bad-has 'main-raced'
tooth "main-raced check dropped" $T 's/if \[ "\$(git -C "\$repo" rev-parse "\$base^" 2>\/dev\/null)" != "\$exp_tip" \]; then/if false; then/' 31 32 main-raced --bad-has 'tree-mismatch'
tooth "tree comparison dropped" $T 's/^  \[ "\$got" = "\$want" \] || finish 32/  true || finish 32/' 32 0 tree-mismatch --bad-lacks 'tree-mismatch'
tooth "prefix tree not rebuilt" $T 's/if \[ "\${#merged_ok\[@\]}" -eq "\${#merged\[@\]}" \]; then/if true; then/' 19 32 mgfail-mid --bad-has 'tree-mismatch'
tooth "stacked-PR base check dropped" $T 's/then why="base-not-\$base_branch"/then why=/' 27 0 stacked --good-lacks '^MERGE 2' --bad-has '^MERGE 2'
tooth "out-of-band head check dropped" $W 's/\[ "\${info%% \*}" != "\$expect_head" \]/false/' 33 0 oob --good-lacks 'merged: all' --bad-has '^MERGE 3'
tooth "interrupt trap removed" $T "s/^trap 'finish 29 train-error \"interrupted\"' INT TERM\$/true/" 29 143 term --bad-lacks 'interrupted'
tooth "bisect lock timeout read as red" $T 's/22) incomplete=gate-lock-timeout; break ;;/22) hi=$mid ;;/' 26 26 bisect-locktimeout --good-has 'bisect-incomplete' --bad-lacks 'bisect-incomplete'
tooth "full gate log not restored after bisect" $T 's/^    gate_rc="\$final_gate_rc" gate_log="\$final_gate_log"$/    true/' 26 26 bisect-locktimeout --good-lacks 'gate-train-[0-9-]*-bisect' --bad-has 'gate-train-[0-9-]*-bisect'
tooth "train refs not removed" $T 's/^  for p in "\${prs\[@\]}"; do git -C "\$repo" update-ref -d .*; done$/  true/' 0 0 happy --good-lacks 'train-refs: refs/train' --bad-has 'train-refs: refs/train'
tooth "dependency probe blind" $C 's/command -v "\$d" >\/dev\/null 2>&1 ||/true ||/' 3 28 nojq --bad-lacks 'degraded: missing'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
