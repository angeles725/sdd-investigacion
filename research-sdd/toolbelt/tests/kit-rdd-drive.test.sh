#!/usr/bin/env bash
# kit-rdd-drive.test.sh — kit issue #2212: maint/kit-rdd-drive.py (follow gentle-ai next_transition to a terminal).
#
# Hermetic: PATH holds only shims (fixtures/kit-pr-pipeline) that record each gentle-ai call and answer from JSON
# fixtures. Under test: execute / collect / stop handling, reviewer captures launched CONCURRENTLY and in provider
# order (a barrier in the shim times out a serial caller), only provider-issued operations run verbatim, and a
# non-approval stop (correction_required, lens_context_budget_exceeded, ...) ends the run with its reason code.
#
# Usage: kit-rdd-drive.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
#        kit-rdd-drive.test.sh --scenario NAME SUT  (internal: one case against SUT, used by the teeth)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SELF="$HERE/kit-rdd-drive.test.sh"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/maint/kit-rdd-drive.py"
FIX="$HERE/fixtures/kit-pr-pipeline"
# shellcheck source=fixtures/kit-pr-pipeline/harness.sh
. "$FIX/harness.sh" || exit 2
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_py_replace mutant_tooth || exit 2
PY="$(command -v python3)" || { echo "FATAL: python3 not on PATH" >&2; exit 2; }
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
OUT=''; RC=0; CALLS=''

# run_case NAME SUT [extra args...] — sets OUT, RC, CALLS
run_case() {
  local name="$1" sut="$2"; shift 2
  local first="$FIX/start-granted.json"
  kh_init "$TMP" || return 2
  case "$name" in
    approve)
      kh_rule gentle-ai 'review status*' 0 status-collect.json
      kh_rule gentle-ai 'review capture-result --lens risk' 0 capture-pending.json 1 barrier=cap:2
      kh_rule gentle-ai 'review capture-result --lens resilience' 0 capture-final-approved.json 1 barrier=cap:2
      kh_rule gentle-ai 'review acknowledge-approved*' 0 ack.json ;;
    rebound)  # both captures admitted but not terminal -> the bound STATUS is asked again
      kh_rule gentle-ai 'review status*' 0 status-collect.json 1
      kh_rule gentle-ai 'review status*' 0 status-stop-acked.json
      kh_rule gentle-ai 'review capture-result*' 0 capture-pending.json ;;
    correction-collect) kh_rule gentle-ai 'review status*' 0 status-correction.json ;;
    correction-final)
      kh_rule gentle-ai 'review status*' 0 status-collect.json 1
      kh_rule gentle-ai 'review status*' 0 status-stop-correction.json
      kh_rule gentle-ai 'review capture-result --lens risk' 0 capture-pending.json
      kh_rule gentle-ai 'review capture-result --lens resilience' 0 capture-final-correction.json ;;
    budget) kh_rule gentle-ai 'review status*' 0 status-stop-budget.json ;;
    acked) kh_rule gentle-ai 'review status*' 0 status-stop-acked.json ;;
    consent) first="$FIX/consent.json" ;;
    notrans) kh_rule gentle-ai 'review status*' 0 status-notrans.json ;;
    loop) kh_rule gentle-ai 'review status*' 0 start-granted.json ;;
    nogentle) kh_drop gentle-ai ;;
    badop-nodot) kh_rule gentle-ai 'review status*' 0 bad-op-nodot.json ;;
    badop-nonreview) kh_rule gentle-ai 'review status*' 0 bad-op-nonreview.json ;;
    bad-noargs) kh_rule gentle-ai 'review status*' 0 bad-noargs.json ;;
    bad-token) kh_rule gentle-ai 'review status*' 0 bad-token.json ;;
    bad-collect-empty) kh_rule gentle-ai 'review status*' 0 bad-collect-empty.json ;;
    bad-collect-nokey) kh_rule gentle-ai 'review status*' 0 bad-collect-nokey.json ;;
    bad-statuslist) kh_rule gentle-ai 'review status*' 0 list.json ;;
    bad-firstlist) first="$FIX/list.json" ;;
  esac
  if [ "$name" = usage ]; then
    OUT="$(cd "$KH_WT" && PATH="$KH_BIN" "$PY" -I "$sut" 2>&1)"; RC=$?
  else
    OUT="$(cd "$KH_WT" && PATH="$KH_BIN" "$PY" -I "$sut" "$@" "$KH_WT" "$first" 2>&1)"; RC=$?
  fi
  CALLS="$(kh_calls)"
}
launch_order() { grep '^LAUNCH' <<<"$OUT" | sed -E 's/.*--lens ([a-z]+).*/\1/' | tr '\n' ',' | sed 's/,$//'; }

if [ "${1:-}" = "--scenario" ]; then
  s="${2:?scenario}"; sut="${3:?sut}"
  run_case "$s" "$sut"
  printf '%s\n--calls--\n%s\nLAUNCH-ORDER=%s\n' "$OUT" "$CALLS" "$(launch_order)"
  exit "$RC"
fi

echo "== kit-rdd-drive.test.sh =="

run_case approve "$SUT"
if [ "$RC" = 0 ] && [[ "$OUT" == *ACKNOWLEDGED* ]]; then ok "execute -> collect -> captures -> acknowledge: ends ACKNOWLEDGED, rc 0"
else no "approve flow rc=$RC out=[$OUT]"; fi
if [ "$(launch_order)" = "risk,resilience" ]; then ok "reviewer captures are launched in provider order"
else no "launch order [$(launch_order)]"; fi
# the shim barrier (cap:2) only releases when both captures run at once: a serial driver gets rc 98 from it
if ! grep -q 'barrier timeout' <<<"$OUT" && grep -qxF 'gentle-ai review capture-result --lens risk' <<<"$CALLS" \
   && grep -qxF 'gentle-ai review capture-result --lens resilience' <<<"$CALLS"; then
  ok "both captures ran concurrently (the barrier released)"
else no "captures not concurrent: out=[$OUT]"; fi
if grep -qxF 'gentle-ai review acknowledge-approved --lineage L1 --token ACK1' <<<"$CALLS" \
   && grep -qxF 'gentle-ai review status --cwd /x --lineage L1' <<<"$CALLS"; then
  ok "operations run exactly as provider-issued: operation name + ordered tokens"
else no "operations not verbatim: calls=[$CALLS]"; fi

if [ "$(tail -1 <<<"$CALLS")" = 'gentle-ai review acknowledge-approved --lineage L1 --token ACK1' ]; then ok "no STATUS (or any call) follows acknowledge-approved"
else no "calls after acknowledge: [$CALLS]"; fi

run_case rebound "$SUT"
if [ "$RC" = 0 ] && [ "$(grep -c '^gentle-ai review status' <<<"$CALLS")" = 2 ]; then ok "non-terminal captures -> the bound STATUS is asked again, then the stop is honoured"
else no "rebound rc=$RC calls=[$CALLS]"; fi

run_case correction-collect "$SUT"
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: non-capture-collect (review.capture-correction-plan)'* ]] \
   && [[ "$OUT" != *correction_required* ]] && ! grep -q 'capture-correction-plan' <<<"$CALLS"; then
  ok "a non-capture collect stops as 'non-capture-collect (<op>)': no reason code is invented, nothing is run"
else no "correction collect rc=$RC out=[$OUT] calls=[$CALLS]"; fi

run_case correction-final "$SUT"
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: correction_required'* ]]; then ok "a final capture that opens correction_required stops with that code"
else no "correction final rc=$RC out=[$OUT]"; fi

run_case budget "$SUT"
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: lens_context_budget_exceeded'* ]]; then ok "stop lens_context_budget_exceeded -> rc 13 with the reason code"
else no "budget stop rc=$RC out=[$OUT]"; fi

run_case acked "$SUT"
if [ "$RC" = 0 ] && [[ "$OUT" == *'rdd-stop: target_already_acknowledged'* ]]; then ok "stop target_already_acknowledged is terminal and rc 0"
else no "acked rc=$RC out=[$OUT]"; fi

run_case consent "$SUT"
if [ "$RC" = 15 ] && [[ "$OUT" == *consent-required* ]] && [[ "$OUT" == *'--consent granted --target T1'* ]] && [ -z "$CALLS" ]; then
  ok "a consent envelope as the document -> rc 15, printed, nothing run"
else no "consent doc rc=$RC out=[$OUT] calls=[$CALLS]"; fi

run_case notrans "$SUT"
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: no-transition'* ]]; then ok "a document with no transition -> rc 13 no-transition"
else no "no transition rc=$RC out=[$OUT]"; fi

run_case loop "$SUT" --max-steps 3
if [ "$RC" = 13 ] && [[ "$OUT" == *'rdd-stop: step-limit'* ]]; then ok "a STATUS that never terminates hits the step limit -> rc 13"
else no "step limit rc=$RC out=[$OUT]"; fi

run_case nogentle "$SUT"
if [ "$RC" = 3 ] && [[ "$OUT" == *'degraded: missing runtime dependency: gentle-ai'* ]]; then ok "gentle-ai absent -> rc 3 degraded, typed"
else no "nogentle rc=$RC out=[$OUT]"; fi

run_case usage "$SUT"
if [ "$RC" = 2 ]; then ok "missing arguments -> rc 2 usage"; else no "usage rc=$RC"; fi


# ---- malformed provider output -> rdd-protocol-error (rc 14), never a traceback; allowlist of operations ----
for nm in badop-nodot badop-nonreview bad-noargs bad-token bad-collect-empty bad-collect-nokey bad-statuslist bad-firstlist; do
  run_case "$nm" "$SUT"
  if [ "$RC" = 14 ] && [[ "$OUT" == *rdd-protocol-error* ]] && [[ "$OUT" != *Traceback* ]]; then ok "$nm -> rc 14 rdd-protocol-error, no traceback"
  else no "$nm: rc=$RC out=[$OUT]"; fi
done
run_case badop-nonreview "$SUT"
if ! grep -qE 'shell|exec' <<<"$CALLS"; then ok "an operation outside review.* is never turned into a command"
else no "non-review operation ran: calls=[$CALLS]"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: kit-rdd-drive mutation controls --"
MUT="$TMP/mut"; mkdir -p "$MUT"
tooth() { # LABEL OLD NEW GOOD_RC BAD_RC SCENARIO [tooth opts...]
  local label="$1" old="$2" new="$3" g="$4" b="$5" sc="$6"; shift 6
  local m="$MUT/${label// /_}.py"
  if ! mutant_py_replace "$label" "$SUT" "$old" "$new" "$m"; then no "tooth $label: mutant refused"; return; fi
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$SELF" --scenario "$sc" @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "captures run serially" 'max_workers=len(cmds)' 'max_workers=1' 0 0 approve --good-lacks 'barrier timeout' --bad-has 'barrier timeout'
tooth "captures launched out of order" 'for i in inputs]' 'for i in inputs][::-1]' 0 0 approve --good-has 'LAUNCH-ORDER=risk,resilience' --bad-lacks 'LAUNCH-ORDER=risk,resilience'
tooth "non-capture collect no longer stops" 'if odd:' 'if False:' 13 13 correction-collect --good-has 'rdd-stop: non-capture-collect' --bad-lacks 'rdd-stop: non-capture-collect'
tooth "operation allowlist removed" 'not op.startswith("review.")' 'False' 14 13 badop-nonreview
tooth "every stop treated as success" 'sys.exit(0 if reason == "target_already_acknowledged" else 13)' 'sys.exit(0)' 13 0 budget
tooth "consent document no longer stops" 'sys.exit(15)' 'sys.exit(0)' 15 0 consent
tooth "step limit cut to two" 'for step in range(args.max_steps):' 'for step in range(2):' 0 13 approve
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
