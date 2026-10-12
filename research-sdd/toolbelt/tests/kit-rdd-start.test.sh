#!/usr/bin/env bash
# kit-rdd-start.test.sh — kit issue #2212: maint/kit-rdd-start.py (assess -> STATUS -> START -> explicit consent).
#
# Hermetic: the case PATH holds only shims (fixtures/kit-pr-pipeline/shim.sh + harness.sh) that record every
# gentle-ai call and answer from JSON fixtures. Nothing reaches the real gentle-ai, gh or git.
# Contract under test (header of the SUT): the starter runs ONLY provider-issued commands, and picks the
# provider's `granted` choice ONLY when `--consent granted` is passed; otherwise it prints the consent
# envelope losslessly and exits 15 (consent-required) without running a granted/declined invocation.
#
# Usage: kit-rdd-start.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
#        kit-rdd-start.test.sh --scenario NAME SUT  (internal: one case against SUT, used by the teeth)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SELF="$HERE/kit-rdd-start.test.sh"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/maint/kit-rdd-start.py"
# shellcheck source=fixtures/kit-pr-pipeline/harness.sh
. "$HERE/fixtures/kit-pr-pipeline/harness.sh" || exit 2
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

due_rules() {
  kh_rule gentle-ai 'review assess*' 0 assess-due.json
  kh_rule gentle-ai 'review status*' 0 status-start.json
}
# run_case NAME SUT [extra args...] — sets OUT (stdout+stderr), RC, CALLS, OUTF
run_case() {
  local name="$1" sut="$2"; shift 2
  kh_init "$TMP" || return 2
  OUTF="$KH_CASE/rdd.json"
  case "$name" in
    notdue) kh_rule gentle-ai 'review assess*' 0 assess-notdue.json ;;
    consent) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent.json
             kh_rule gentle-ai 'review start --cwd /x --consent granted*' 0 start-granted.json ;;
    direct) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 start-granted.json ;;
    dup) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent-dup.json
         kh_rule gentle-ai 'review start --consent granted*' 0 start-granted.json ;;
    evil) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent-evil.json ;;
    nonjson) kh_rule gentle-ai 'review assess*' 0 head.txt ;;
    assess-rc1) kh_rule gentle-ai 'review assess*' 1 assess-notdue.json ;;
    assess-nokey) kh_rule gentle-ai 'review assess*' 0 assess-nokey.json ;;
    assess-string) kh_rule gentle-ai 'review assess*' 0 assess-string.json ;;
    assess-list) kh_rule gentle-ai 'review assess*' 0 list.json ;;
    assess-nocmd) kh_rule gentle-ai 'review assess*' 0 assess-due-nocmd.json ;;
    assess-shcmd) kh_rule gentle-ai 'review assess*' 0 assess-due-shcmd.json ;;
    assess-assesscmd) kh_rule gentle-ai 'review assess*' 0 assess-due-assesscmd.json ;;
    status-list) kh_rule gentle-ai 'review status*' 0 list.json; kh_rule gentle-ai 'review assess*' 0 assess-due.json ;;
    status-badargs) kh_rule gentle-ai 'review status*' 0 status-bad-args.json; kh_rule gentle-ai 'review assess*' 0 assess-due.json ;;
    consent-wrongop) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent-wrongop.json ;;
    consent-badchoices) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent-badchoices.json ;;
    refused) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 start-refused.json ;;
    refused-granted) due_rules; kh_rule gentle-ai 'review start --cwd /x --contract*' 0 consent.json
                     kh_rule gentle-ai 'review start --cwd /x --consent granted*' 0 start-refused.json ;;
    notstart) kh_rule gentle-ai 'review assess*' 0 assess-due.json
              kh_rule gentle-ai 'review status*' 0 status-not-start.json ;;
    nogentle) kh_drop gentle-ai ;;
    usage) ;;
  esac
  if [ "$name" = usage ]; then
    OUT="$(cd "$KH_WT" && PATH="$KH_BIN" "$PY" -I "$sut" 2>&1)"; RC=$?
  else
    OUT="$(cd "$KH_WT" && PATH="$KH_BIN" "$PY" -I "$sut" "$@" "$KH_WT" "$OUTF" 2>&1)"; RC=$?
  fi
  CALLS="$(kh_calls)"
}

if [ "${1:-}" = "--scenario" ]; then
  s="${2:?scenario}"; sut="${3:?sut}"
  case "$s" in
    granted) run_case consent "$sut" --consent granted ;;
    dup-granted) run_case dup "$sut" --consent granted ;;
    evil-granted) run_case evil "$sut" --consent granted ;;
    *+g) run_case "${s%+g}" "$sut" --consent granted ;;
    *) run_case "$s" "$sut" ;;
  esac
  printf '%s\n--calls--\n%s\n' "$OUT" "$CALLS"
  [ -e "$KH_WT/PWNED" ] && echo "PWNED=yes"
  exit "$RC"
fi

echo "== kit-rdd-start.test.sh =="

run_case notdue "$SUT"
if [ "$RC" = 10 ] && [[ "$OUT" == *rdd-not-due* ]] && ! grep -q 'review status' <<<"$CALLS" && [ ! -e "$OUTF" ]; then
  ok "not due -> rc 10 rdd-not-due, no STATUS call, no output file"
else no "not due: rc=$RC out=[$OUT] calls=[$CALLS]"; fi

run_case consent "$SUT"
if [ "$RC" = 15 ] && [[ "$OUT" == *consent-required* ]]; then ok "consent envelope without --consent -> rc 15 consent-required"
else no "consent-required rc=$RC out=[$OUT]"; fi
if [[ "$OUT" == *'gentle-ai review start --cwd /x --consent declined --target T1'* ]] \
   && [[ "$OUT" == *'gentle-ai review start --cwd /x --consent granted --target T1'* ]] \
   && [[ "$OUT" == *'Review this candidate?'* ]] && [[ "$OUT" == *'native review runs'* ]]; then
  ok "the consent envelope is printed losslessly (headline, effects, both invocations)"
else no "envelope not lossless: out=[$OUT]"; fi
if [ "$(grep -c '^gentle-ai review start' <<<"$CALLS")" = 1 ] && ! grep -q -- '--consent' <<<"$CALLS" && [ ! -e "$OUTF" ]; then
  ok "without --consent only the provider START ran: no granted/declined invocation, no output file"
else no "extra START invocations: calls=[$CALLS]"; fi

run_case consent "$SUT" --consent granted
if [ "$RC" = 0 ] && grep -qxF 'gentle-ai review start --cwd /x --consent granted --target T1' <<<"$CALLS" \
   && ! grep -q -- '--consent declined' <<<"$CALLS"; then
  ok "--consent granted runs exactly the provider's granted invocation, verbatim (declined never run)"
else no "granted path: rc=$RC calls=[$CALLS] out=[$OUT]"; fi
if [ "$RC" = 0 ] && cmp -s <(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$OUTF" 2>/dev/null) \
   <(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$HERE/fixtures/kit-pr-pipeline/start-granted.json"); then
  ok "the granted START output is written to the output file unchanged"
else no "output file differs from the provider's answer"; fi
if grep -qxF "gentle-ai review assess --cwd $KH_WT --agent claude-code --base-ref origin/main --committed-only --json" <<<"$CALLS" \
   && grep -qxF 'gentle-ai review start --cwd /x --contract gentle-ai.review-integration/v2' <<<"$CALLS"; then
  ok "assess uses the documented selectors; START uses the provider-issued tokens in order"
else no "assess/start tokens: calls=[$CALLS]"; fi

run_case direct "$SUT"
if [ "$RC" = 0 ] && [ -s "$OUTF" ] && ! grep -q -- '--consent' <<<"$CALLS"; then ok "START without a consent envelope -> rc 0, output written, no consent invocation"
else no "direct start rc=$RC calls=[$CALLS]"; fi

run_case dup "$SUT" --consent granted
if [ "$RC" = 14 ] && [[ "$OUT" == *rdd-start-error* ]] && ! grep -q -- '--consent granted' <<<"$CALLS"; then
  ok "two granted choices -> rc 14 rdd-start-error, nothing run"
else no "dup granted rc=$RC calls=[$CALLS]"; fi

run_case evil "$SUT" --consent granted
if [ "$RC" = 14 ] && [ ! -e "$KH_WT/PWNED" ]; then ok "a granted invocation whose argv[0] is not gentle-ai is refused, not executed"
else no "non-gentle-ai invocation ran: rc=$RC pwned=$([ -e "$KH_WT/PWNED" ] && echo yes)"; fi

run_case nonjson "$SUT"
if [ "$RC" = 14 ] && [[ "$OUT" == *rdd-start-error* ]]; then ok "non-JSON assess output -> rc 14 rdd-start-error"
else no "nonjson rc=$RC out=[$OUT]"; fi

run_case notstart "$SUT"
if [ "$RC" = 14 ] && [[ "$OUT" == *rdd-start-error* ]]; then ok "STATUS that is not a review.start execute -> rc 14"
else no "notstart rc=$RC out=[$OUT]"; fi

run_case nogentle "$SUT"
if [ "$RC" = 3 ] && [[ "$OUT" == *'degraded: missing runtime dependency: gentle-ai'* ]]; then ok "gentle-ai absent -> rc 3 degraded, typed"
else no "nogentle rc=$RC out=[$OUT]"; fi

run_case usage "$SUT"
if [ "$RC" = 2 ]; then ok "missing arguments -> rc 2 usage"; else no "usage rc=$RC"; fi


# ---- hardening (Opus review of #2212): exact not-due, strict allowlist, malformed provider output ----
# expect_typed NAME WANT_RC LABEL [args...] — rc, the typed state line, no raw traceback, nothing planted ran
expect_typed() {
  local nm="$1" want="$2" label="$3"; shift 3
  run_case "$nm" "$SUT" "$@"
  if [ "$RC" = "$want" ] && [[ "$OUT" != *Traceback* ]] && [ ! -e "$KH_WT/PWNED" ]; then ok "$label"
  else no "$label: rc=$RC (want $want) out=[$OUT]"; fi
}
expect_typed assess-rc1 14 "assess rc 1 (even with review_due false) -> rc 14, never 'not due'"
expect_typed assess-nokey 14 "assess answer without review_due -> rc 14, never 'not due'"
expect_typed assess-string 14 "review_due as a string -> rc 14 (exact bool only)"
expect_typed assess-list 14 "assess answer that is not a JSON object -> rc 14, no traceback"
expect_typed assess-nocmd 14 "due assess without next_transition.command -> rc 14, no traceback"
expect_typed status-list 14 "STATUS answer that is not a JSON object -> rc 14, no traceback"
expect_typed status-badargs 14 "START argument without a token -> rc 14, no traceback"
expect_typed consent-badchoices 14 "consent choices that are not objects -> rc 14, no traceback" --consent granted
expect_typed assess-shcmd 14 "a STATUS command that is not 'gentle-ai review status' (sh -c) is refused, not run"
run_case assess-assesscmd "$SUT"
if [ "$RC" = 14 ] && [ "$(grep -c '^gentle-ai review assess' <<<"$CALLS")" = 1 ]; then ok "a STATUS command 'gentle-ai review assess' is refused (allowlist is argv[:3] == gentle-ai review status)"
else no "assess-as-status ran: rc=$RC calls=[$CALLS]"; fi
run_case consent-wrongop "$SUT" --consent granted
if [ "$RC" = 14 ] && [ "$(grep -c '^gentle-ai review status' <<<"$CALLS")" = 1 ]; then ok "a granted invocation that is not 'gentle-ai review start' is refused, not run"
else no "granted wrong op ran: rc=$RC calls=[$CALLS]"; fi
run_case refused "$SUT"
if [ "$RC" = 14 ] && [[ "$OUT" != *'kit-rdd-start: started'* ]] && [[ "$OUT" == *rdd-start-error* ]]; then ok "a refused START (no continuation) -> rc 14, never reported as started"
else no "refused START reported: rc=$RC out=[$OUT]"; fi
run_case refused-granted "$SUT" --consent granted
if [ "$RC" = 14 ] && [[ "$OUT" != *'kit-rdd-start: started'* ]]; then ok "a refused granted START -> rc 14, never reported as started"
else no "refused granted START reported: rc=$RC out=[$OUT]"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: kit-rdd-start mutation controls --"
MUT="$TMP/mut"; mkdir -p "$MUT"
tooth() { # LABEL OLD NEW GOOD_RC BAD_RC SCENARIO [tooth opts...]
  local label="$1" old="$2" new="$3" g="$4" b="$5" sc="$6"; shift 6
  local m="$MUT/${label// /_}.py"
  if ! mutant_py_replace "$label" "$SUT" "$old" "$new" "$m"; then no "tooth $label: mutant refused"; return; fi
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$SELF" --scenario "$sc" @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "consent gate removed" 'if args.consent != "granted":' 'if False:' 15 0 consent --bad-lacks 'consent-required'
tooth "unique granted check weakened" 'if len(granted) != 1:' 'if len(granted) < 1:' 14 0 dup-granted
tooth "argv0 check removed" 'if inv[:3] != ["gentle-ai", "review", "start"]:' 'if False:' 14 14 evil-granted --good-lacks 'PWNED=yes' --bad-has 'PWNED=yes'
tooth "not-due gate removed" 'if assess_rc == 0 and assess.get("review_due") is False:' 'if False:' 10 14 notdue
tooth "envelope no longer lossless" 'print(json.dumps(env, indent=2, sort_keys=True))' 'print("envelope omitted")' 15 15 consent --good-has 'consent declined' --bad-lacks 'consent declined'
tooth "not-due needs rc 0" 'if assess_rc == 0 and assess.get("review_due") is False:' 'if assess.get("review_due") is False:' 14 10 assess-rc1
tooth "not-due must be an exact bool" 'if assess_rc == 0 and assess.get("review_due") is False:' 'if not assess.get("review_due"):' 14 10 assess-nokey
tooth "STATUS allowlist removed" 'if status_cmd[:3] != ["gentle-ai", "review", "status"]:' 'if False:' 14 14 assess-shcmd --good-lacks 'PWNED=yes' --bad-has 'PWNED=yes'
tooth "granted allowlist removed" 'if inv[:3] != ["gentle-ai", "review", "start"]:' 'if False:' 14 0 consent-wrongop+g
tooth "refused START reported as started" 'if not isinstance(doc.get("next_transition") or doc.get("status_continuation"), dict):' 'if False:' 14 0 refused
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
