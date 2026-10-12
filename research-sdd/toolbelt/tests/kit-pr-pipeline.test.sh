#!/usr/bin/env bash
# kit-pr-pipeline.test.sh — kit issue #2212: maint/kit-pr-pipeline.sh, kit-gate.sh, kit-wait-merge.sh.
#
# The pipeline (restack -> push -> RDD -> flock'd full gate -> CI wait -> merge-gate --merge) is driven end to end
# against PATH shims for git / gh / gentle-ai / flock (fixtures/kit-pr-pipeline/shim.sh), which record each call in
# one ordered log and answer from fixtures. The real kit-rdd-start.py / kit-rdd-drive.py run against the gentle-ai
# shim, so the whole chain is exercised. Nothing here reaches the network, a real repository or gentle-ai.
# Typed exit states are asserted by exit code AND by the `kit-pr-pipeline: <state>` line (table in the SUT header).
#
# Usage: kit-pr-pipeline.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
#        kit-pr-pipeline.test.sh --scenario NAME STAGEDIR  (internal: one case against the tools staged in STAGEDIR)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SELF="$HERE/kit-pr-pipeline.test.sh"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
MAINT="$TB/maint"
FIX="$HERE/fixtures/kit-pr-pipeline"
# shellcheck source=fixtures/kit-pr-pipeline/harness.sh
. "$FIX/harness.sh" || exit 2
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_sed mutant_tooth || exit 2
for f in kit-pr-pipeline.sh kit-gate.sh kit-wait-merge.sh kit-maint-common.sh kit-rdd-start.py kit-rdd-drive.py; do
  [ -f "$MAINT/$f" ] || { echo "FATAL: SUT not found: $MAINT/$f" >&2; exit 2; }
done
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
OUT=''; RC=0; CALLS=''
STAGE="$MAINT"

happy_rules() { # defaults, appended AFTER a case's own rules (the first matching rule wins)
  kh_rule git 'fetch*' 0
  kh_rule git 'merge-base --is-ancestor*' 1
  kh_rule git 'merge -q --no-edit*' 0
  kh_rule git 'push*' 0
  kh_rule git 'rev-parse --short HEAD' 0 head.txt
  kh_rule gentle-ai 'review assess*' 0 assess-due.json
  kh_rule gentle-ai 'review status --cwd /x --contract*' 0 status-start.json
  kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent.json
  kh_rule gentle-ai 'review start --cwd /x --consent granted*' 0 start-granted.json
  kh_rule gentle-ai 'review status --cwd /x --lineage*' 0 status-collect.json
  kh_rule gentle-ai 'review capture-result --lens risk' 0 capture-pending.json - barrier=cap:2
  kh_rule gentle-ai 'review capture-result --lens resilience' 0 capture-final-approved.json - barrier=cap:2
  kh_rule gentle-ai 'review acknowledge-approved*' 0 ack.json
  kh_rule flock '*' 0
  kh_rule gh 'pr checks*' 0 pr-checks-pass.txt
  kh_rule gh 'pr view*' 0 pr-state-merged.txt
  kh_rule merge-gate.sh '*' 0 merge-gate-merged.txt
}
GATE_OK='echo GATE-RAN >> "$SHIM_STATE/calls.log"'

# run_pipeline NAME [pipeline args...] — builds the case, runs STAGE/kit-pr-pipeline.sh <wt> 7 feat/x
run_pipeline() {
  local name="$1"; shift
  kh_init "$TMP" || return 2
  ln -s "$FIX/shim.sh" "$KH_CASE/merge-gate.sh"
  case "$name" in
    happy|dry|nogate|sizecheck-ok|sizefail|usage-state-in-repo) ;;
    conflict) kh_rule git 'merge -q --no-edit*' 1 ;;
    fetchfail) kh_rule git 'fetch*' 1 ;;
    pushfail) kh_rule git 'push*' 1 ;;
    pushblip) kh_rule git 'push*' 1 - 1 ;;
    consent-none) ;;
    notdue) kh_rule gentle-ai 'review assess*' 0 assess-notdue.json ;;
    rdd-stop) kh_rule gentle-ai 'review status --cwd /x --lineage*' 0 status-stop-budget.json ;;
    rdd-correction) kh_rule gentle-ai 'review status --cwd /x --lineage*' 0 status-correction.json ;;
    rdd-err) kh_rule gentle-ai 'review assess*' 0 head.txt ;;
    gatefail) ;;
    cifail) kh_rule gh 'pr checks*' 1 pr-checks-fail.txt ;;
    degraded-then-ok) kh_rule merge-gate.sh '*' 3 merge-gate-degraded.txt 1; kh_rule gh 'pr view*' 0 pr-state-open.txt 1 ;;
    degraded-forever) kh_rule merge-gate.sh '*' 3 merge-gate-degraded.txt; kh_rule gh 'pr view*' 0 pr-state-open.txt ;;
    review-due) kh_rule merge-gate.sh '*' 1 merge-gate-review-due.txt; kh_rule gh 'pr view*' 0 pr-state-open.txt ;;
    nogh) kh_drop gh ;;
    noflock) kh_drop flock ;;
  esac
  happy_rules
  local -a extra=("$@")
  extra=("${extra[@]//@WT@/"$KH_WT"}")   # a literal @WT@ in an argument stands for this case's worktree
  case "$name" in
    happy|nogate|sizecheck-ok|sizefail|fetchfail|pushfail|pushblip|conflict|cifail|degraded-then-ok|degraded-forever|review-due|rdd-stop|rdd-correction|notdue|rdd-err|nogh|noflock)
      extra=(--consent granted --gate-cmd "$GATE_OK" "${extra[@]}") ;;
    consent-none|dry) extra=(--gate-cmd "$GATE_OK" "${extra[@]}") ;;
    gatefail) extra=(--consent granted --gate-cmd 'echo GATE-BAD; exit 1' "${extra[@]}") ;;
  esac
  case "$name" in dry) extra=(--consent granted --dry-run "${extra[@]}") ;; esac
  [ "$name" = sizefail ] && extra=(--size-check 'exit 1' "${extra[@]}")
  OUT="$(cd "$KH_WT" && PATH="$KH_BIN" HOME="$KH_CASE" XDG_STATE_HOME="$KH_CASE/xdg" KIT_RETRY_SLEEP=0 KIT_POLL_SLEEP=0 \
         KIT_MERGE_SLEEP=0 KIT_MERGE_GATE="$KH_CASE/merge-gate.sh" bash "$STAGE/kit-pr-pipeline.sh" "${extra[@]}" "$KH_WT" 7 feat/x 2>&1)"
  RC=$?
  CALLS="$(kh_calls)"
}
nth() { grep -nE -- "$1" <<<"$CALLS" | head -1 | cut -d: -f1; }   # first line number of a call, empty when absent
count() { grep -cE -- "$1" <<<"$CALLS"; }

if [ "${1:-}" = "--scenario" ]; then
  STAGE="$(dirname "${3:?staged SUT path}")"
  run_pipeline "${2:?scenario}"
  printf '%s\n--calls--\n%s\n' "$OUT" "$CALLS"
  exit "$RC"
fi

echo "== kit-pr-pipeline.test.sh =="

# ---- happy path: the documented order, restack -> push -> RDD -> gate -> CI -> merge ----
run_pipeline happy
a=$(nth '^git fetch'); b=$(nth '^git merge -q --no-edit origin/main'); c=$(nth '^git push -q origin HEAD:feat/x')
d=$(nth '^gentle-ai review assess'); e=$(nth '^gentle-ai review start --cwd /x --consent granted'); f=$(nth '^gentle-ai review acknowledge-approved')
g=$(nth '^GATE-RAN'); h=$(nth '^gh pr checks 7'); i=$(nth '^merge-gate.sh --cwd .* --merge 7')
if [ "$RC" = 0 ] && [[ "$OUT" == *'kit-pr-pipeline: merged'* ]]; then ok "happy path ends merged, rc 0"
else no "happy rc=$RC out=[$OUT]"; fi
if [ -n "$a" ] && [ -n "$i" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] \
   && [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ] && [ "$g" -lt "$h" ] && [ "$h" -lt "$i" ]; then
  ok "call order: fetch < restack < push < assess < granted START < acknowledge < gate < CI wait < merge-gate"
else no "call order wrong: [$a $b $c $d $e $f $g $h $i] calls=[$CALLS]"; fi
if grep -qxF "flock 9" <<<"$CALLS" && [ "$(nth '^flock 9')" -lt "$g" ]; then ok "the gate ran under the flock (flock before the gate command)"
else no "gate not under flock: calls=[$CALLS]"; fi
if grep -qE "^merge-gate.sh --cwd $KH_WT --base-ref origin/main --merge 7" <<<"$CALLS"; then ok "merge-gate is called with --cwd <worktree> --base-ref origin/main --merge <pr>"
else no "merge-gate args: calls=[$CALLS]"; fi
if [ -s "$KH_CASE/xdg/research-sdd/pipeline/rdd-7.json" ] && [ -e "$KH_CASE/xdg/research-sdd/pipeline/gate.lock" ]; then
  ok "state lives in \$XDG_STATE_HOME/research-sdd/pipeline (not in the repo)"
else no "state dir default: $(find "$KH_CASE" -name 'rdd-7.json' -o -name 'gate.lock' | tr '\n' ' ')"; fi

# ---- restack ----
run_pipeline conflict
if [ "$RC" = 11 ] && [[ "$OUT" == *'kit-pr-pipeline: restack-conflict'* ]] && grep -qxF 'git merge --abort' <<<"$CALLS" \
   && [ -z "$(nth '^git push')" ] && [ -z "$(nth '^gentle-ai')" ]; then
  ok "restack conflict -> rc 11, merge aborted, nothing pushed, no RDD"
else no "conflict rc=$RC out=[$OUT] calls=[$CALLS]"; fi

# ---- fetch / push + network blips ----
run_pipeline fetchfail
if [ "$RC" = 21 ] && [[ "$OUT" == *'kit-pr-pipeline: fetch-failed'* ]] && [ "$(count '^git fetch')" = 3 ] && [ -z "$(nth '^git push')" ]; then
  ok "fetch failing for good -> 3 bounded tries, rc 21 fetch-failed, nothing pushed"
else no "fetchfail rc=$RC fetches=$(count '^git fetch') out=[$OUT]"; fi
run_pipeline pushfail
if [ "$RC" = 12 ] && [[ "$OUT" == *'kit-pr-pipeline: push-failed'* ]] && [ "$(count '^git push')" = 3 ] && [ -z "$(nth '^gentle-ai')" ]; then
  ok "push failing for good -> 3 bounded tries, rc 12 push-failed, no RDD"
else no "pushfail rc=$RC pushes=$(count '^git push') out=[$OUT]"; fi
run_pipeline pushblip
if [ "$RC" = 0 ] && [ "$(count '^git push')" = 2 ]; then ok "a one-off push failure is retried and the pipeline proceeds"
else no "pushblip rc=$RC pushes=$(count '^git push') out=[$OUT]"; fi

# ---- RDD + consent ----
run_pipeline consent-none
if [ "$RC" = 15 ] && [[ "$OUT" == *'kit-pr-pipeline: consent-required'* ]] && [[ "$OUT" == *'consent-required'* ]] \
   && ! grep -q -- '--consent' <<<"$CALLS" && [ -z "$(nth '^GATE-RAN')" ] && [ -z "$(nth '^gh pr checks')" ]; then
  ok "no --consent granted -> rc 15 consent-required, no granted invocation, gate and CI never reached"
else no "consent-none rc=$RC out=[$OUT] calls=[$CALLS]"; fi
if [[ "$OUT" == *'gentle-ai review start --cwd /x --consent declined --target T1'* ]]; then ok "the consent envelope is relayed in full (declined choice visible)"
else no "envelope not relayed: out=[$OUT]"; fi

run_pipeline notdue
if [ "$RC" = 0 ] && [[ "$OUT" == *rdd-not-due* ]] && [ -z "$(nth '^gentle-ai review start')" ] && [ -n "$(nth '^GATE-RAN')" ]; then
  ok "rdd-not-due is informational: no review started, the pipeline continues to the gate and merges"
else no "notdue rc=$RC out=[$OUT]"; fi

run_pipeline rdd-stop
if [ "$RC" = 13 ] && [[ "$OUT" == *'kit-pr-pipeline: rdd-not-approved'* ]] && [[ "$OUT" == *'rdd-stop: lens_context_budget_exceeded'* ]] \
   && [ -z "$(nth '^GATE-RAN')" ]; then
  ok "a non-approval stop -> rc 13 rdd-not-approved, the reason code printed, gate not reached"
else no "rdd-stop rc=$RC out=[$OUT]"; fi
run_pipeline rdd-correction
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: correction_required'* ]] && [ -z "$(nth '^GATE-RAN')" ]; then
  ok "correction_required -> rc 13 with its reason code and no automatic recovery"
else no "rdd-correction rc=$RC out=[$OUT]"; fi
run_pipeline rdd-err
if [ "$RC" = 14 ] && [[ "$OUT" == *'kit-pr-pipeline: rdd-start-error'* ]] && [ -z "$(nth '^GATE-RAN')" ]; then ok "RDD start failure -> rc 14 rdd-start-error"
else no "rdd-err rc=$RC out=[$OUT]"; fi

# ---- gate + CI ----
run_pipeline gatefail
if [ "$RC" = 16 ] && [[ "$OUT" == *'kit-pr-pipeline: gate-failed'* ]] && [ -z "$(nth '^gh pr checks')" ] && [ -z "$(nth '^merge-gate.sh')" ]; then
  ok "a failing gate -> rc 16 gate-failed, stops before CI and merge"
else no "gatefail rc=$RC out=[$OUT]"; fi
run_pipeline cifail
if [ "$RC" = 17 ] && [[ "$OUT" == *'kit-pr-pipeline: ci-failed'* ]] && [ -z "$(nth '^merge-gate.sh')" ]; then ok "a failed CI check -> rc 17 ci-failed, merge-gate never called"
else no "cifail rc=$RC out=[$OUT]"; fi

# ---- merge ----
run_pipeline degraded-then-ok
if [ "$RC" = 0 ] && [ "$(count '^merge-gate.sh')" = 2 ]; then ok "merge-gate degraded once is retried, then the PR merges"
else no "degraded-then-ok rc=$RC mg=$(count '^merge-gate.sh') out=[$OUT]"; fi
run_pipeline degraded-forever
if [ "$RC" = 18 ] && [[ "$OUT" == *'kit-pr-pipeline: merge-degraded'* ]] && [ "$(count '^merge-gate.sh')" = 3 ]; then ok "merge-gate degraded every time -> 3 tries then rc 18 merge-degraded"
else no "degraded-forever rc=$RC mg=$(count '^merge-gate.sh') out=[$OUT]"; fi
run_pipeline review-due
if [ "$RC" = 19 ] && [[ "$OUT" == *'kit-pr-pipeline: not-merged'* ]] && [ "$(count '^merge-gate.sh')" = 1 ]; then ok "a merge-gate refusal that retrying cannot fix -> rc 19 not-merged after one try"
else no "review-due rc=$RC mg=$(count '^merge-gate.sh') out=[$OUT]"; fi

# ---- degraded / dry-run / hooks / usage ----
run_pipeline nogh
if [ "$RC" = 3 ] && [[ "$OUT" == *'degraded: missing runtime dependency: gh'* ]] && [ -z "$CALLS" ]; then ok "missing gh -> rc 3 degraded, probed at startup before any call"
else no "nogh rc=$RC out=[$OUT] calls=[$CALLS]"; fi
run_pipeline noflock
if [ "$RC" = 3 ] && [[ "$OUT" == *'degraded: missing runtime dependency: flock'* ]]; then ok "missing flock -> rc 3 degraded"
else no "noflock rc=$RC out=[$OUT]"; fi

run_pipeline dry --dry-run
if [ "$RC" = 0 ] && [ -z "$CALLS" ] && [[ "$OUT" == *'plan:'* ]] && [ ! -e "$KH_CASE/xdg" ]; then ok "--dry-run prints the plan and mutates nothing (no git/gh/gentle-ai call, no state dir)"
else no "dry rc=$RC calls=[$CALLS] out=[$OUT]"; fi
plan_steps="$(grep -c '^kit-pr-pipeline: plan:' <<<"$OUT")"
if [ "$plan_steps" -ge 6 ]; then ok "the dry-run plan lists restack, push, RDD, gate, CI and merge"; else no "plan steps=$plan_steps out=[$OUT]"; fi

run_pipeline nogate --no-gate
if [ "$RC" = 0 ] && [ -z "$(nth '^GATE-RAN')" ] && [ -z "$(nth '^flock')" ] && [ -n "$(nth '^gh pr checks')" ]; then ok "--no-gate skips the gate (no flock, no gate command) and goes on to CI"
else no "nogate rc=$RC calls=[$CALLS]"; fi

run_pipeline sizecheck-ok --size-check 'echo SIZE-RAN >> "$SHIM_STATE/calls.log"'
if [ "$RC" = 0 ] && [ -n "$(nth '^SIZE-RAN')" ] && [ "$(nth '^SIZE-RAN')" -lt "$(nth '^gentle-ai review assess')" ]; then ok "--size-check runs before RDD"
else no "size-check order: rc=$RC calls=[$CALLS]"; fi
run_pipeline sizecheck-ok --size-check 'exit 1'
if [ "$RC" = 20 ] && [[ "$OUT" == *'kit-pr-pipeline: size-check-failed'* ]] && [ -z "$(nth '^gentle-ai')" ]; then ok "a failing --size-check -> rc 20, stops before RDD"
else no "size-check fail rc=$RC out=[$OUT]"; fi
run_pipeline happy
if [ -z "$(nth '^SIZE-RAN')" ] && [ "$RC" = 0 ]; then ok "without --size-check the hook point is a no-op"; else no "size hook not a no-op"; fi

run_pipeline usage-state-in-repo --state-dir @WT@/state
if [ "$RC" = 2 ] && [ -z "$CALLS" ]; then ok "a --state-dir inside the worktree is refused (rc 2): state never lives in the repo"
else no "state-in-repo rc=$RC out=[$OUT]"; fi
OUT="$(cd "$KH_WT" && PATH="$KH_BIN" bash "$MAINT/kit-pr-pipeline.sh" 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "missing arguments -> rc 2 usage"; else no "usage rc=$RC"; fi

# ---- kit-gate.sh on its own ----
kh_init "$TMP"; kh_rule flock '*' 0; kh_rule git 'rev-parse --short HEAD' 0 head.txt
OUT="$(cd "$KH_WT" && PATH="$KH_BIN" bash "$MAINT/kit-gate.sh" --state-dir "$KH_CASE/st" --cmd 'echo GATE-RAN >> "$SHIM_STATE/calls.log"; echo "AGGREGATE RESULT: 3 passed"; exit 7' "$KH_WT" lbl 2>&1)"; RC=$?
CALLS="$(kh_calls)"
if [ "$RC" = 7 ] && [[ "$OUT" == *'AGGREGATE RESULT'* ]]; then ok "kit-gate exits with the gate's own rc and prints the summary lines"; else no "kit-gate rc=$RC out=[$OUT]"; fi
if [ "$(nth '^flock 9')" = 1 ] && [ "$(nth '^GATE-RAN')" -gt 1 ] && grep -q 'gate rc=7' "$KH_CASE/st/gate-lbl.log" && grep -q '^head abc1234' "$KH_CASE/st/gate-lbl.log"; then
  ok "kit-gate: flock first, then the gate; log holds the head and 'gate rc=7'"
else no "kit-gate log/order: calls=[$CALLS] log=[$(cat "$KH_CASE/st/gate-lbl.log" 2>/dev/null)]"; fi
kh_init "$TMP"; kh_drop flock
OUT="$(cd "$KH_WT" && PATH="$KH_BIN" bash "$MAINT/kit-gate.sh" --state-dir "$KH_CASE/st" --cmd true "$KH_WT" lbl 2>&1)"; RC=$?
if [ "$RC" = 3 ] && [[ "$OUT" == *'degraded: missing runtime dependency: flock'* ]]; then ok "kit-gate without flock -> rc 3 degraded"; else no "kit-gate noflock rc=$RC out=[$OUT]"; fi

# ---- kit-wait-merge.sh on its own ----
kh_init "$TMP"; ln -s "$FIX/shim.sh" "$KH_CASE/merge-gate.sh"
kh_rule gh 'pr checks*' 8 pr-checks-pending.txt 2; kh_rule gh 'pr checks*' 0 pr-checks-pass.txt
kh_rule gh 'pr view*' 1 - 1; kh_rule gh 'pr view*' 0 pr-state-merged.txt; kh_rule merge-gate.sh '*' 0 merge-gate-merged.txt
OUT="$(cd "$KH_WT" && PATH="$KH_BIN" KIT_RETRY_SLEEP=0 KIT_POLL_SLEEP=0 KIT_MERGE_SLEEP=0 KIT_MERGE_GATE="$KH_CASE/merge-gate.sh" \
       bash "$MAINT/kit-wait-merge.sh" "$KH_WT" 7 2>&1)"; RC=$?
CALLS="$(kh_calls)"
if [ "$RC" = 0 ] && [ "$(count '^gh pr checks 7')" = 3 ] && [ "$(count '^gh pr view')" = 2 ]; then ok "kit-wait-merge polls pending checks, retries a gh blip on pr view, then merges"
else no "wait-merge rc=$RC checks=$(count '^gh pr checks 7') view=$(count '^gh pr view') out=[$OUT]"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: kit-pr-pipeline mutation controls --"
n=0
# tooth LABEL FILE SED_EXPR GOOD_RC BAD_RC SCENARIO [mutant_tooth opts...]
# Stages a copy of maint/ in a temp dir, mutates FILE there (mutant_sed refuses an empty, identical or
# syntax-broken mutant), and runs the scenario once against the real tools and once against the staged ones:
# the scenario takes the path of the tool under test and uses its directory.
tooth() {
  local label="$1" file="$2" expr="$3" g="$4" b="$5" sc="$6"; shift 6
  local st="$TMP/stage.$((n += 1))"
  mkdir -p "$st" && cp "$MAINT"/* "$st"/ && rm -f "$st/$file"
  if ! mutant_sed "$MAINT/$file" "$st/$file" "$expr"; then no "tooth $label: mutant refused"; return; fi
  chmod +x "$st"/*.sh "$st"/*.py
  if mutant_tooth "tooth $label" "$g" "$b" "$st/$file" --orig "$MAINT/$file" "$@" -- bash "$SELF" --scenario "$sc" @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
P=kit-pr-pipeline.sh; W=kit-wait-merge.sh; G=kit-gate.sh; C=kit-maint-common.sh
tooth "restack conflict no longer aborts" $P 's/^    git merge --abort$/    true/' 11 11 conflict --good-has 'git merge --abort' --bad-lacks 'git merge --abort'
tooth "consent always passed" $P 's/^\[ "\$consent" = granted \] \&\& start_args/true \&\& start_args/' 15 0 consent-none --bad-has 'kit-pr-pipeline: merged'
tooth "gate failure ignored" $P 's/kit_fail 16 gate-failed/true gate-failed/' 16 0 gatefail --bad-has 'kit-pr-pipeline: merged'
tooth "CI failure ignored" $W 's/kit_fail 17 ci-failed/true ci-failed/' 17 0 cifail --bad-has 'merge-gate.sh --cwd'
tooth "push not retried" $P 's/kit_retry 3 git push/kit_retry 1 git push/' 0 12 pushblip
tooth "degraded merge-gate not retried" $W 's/if \[ "\$mrc" -eq 3 \]; then last=degraded/if false; then last=degraded/' 0 19 degraded-then-ok
tooth "dry-run guard removed" $P 's/^if \[ "\$dry_run" = 1 \]; then/if false; then/' 0 0 dry --good-lacks 'git fetch' --bad-has 'git fetch -q origin'
tooth "size-check failure ignored" $P 's/kit_fail 20 size-check-failed/true size-check-failed/' 20 0 sizefail --bad-has 'kit-pr-pipeline: merged'
tooth "dependency probe blind" $C 's/command -v "\$d" >\/dev\/null 2>&1 ||/true ||/' 3 19 nogh
tooth "gate not under flock" $G 's/^flock 9 ||/true ||/' 0 0 happy --good-has 'flock 9' --bad-lacks 'flock 9'
tooth "gate rc lost" $G 's/^exit "\$rc"$/exit 0/' 16 0 gatefail --bad-has 'kit-pr-pipeline: merged'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
