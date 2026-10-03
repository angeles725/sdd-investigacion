#!/usr/bin/env bash
# sweep-retros-hook.test.sh — red-first harness for sweep-retros-hook.sh.
# Covers: existence, executable, operational-failure banner, success header,
#         summary mode (absent collapse, "N more" limit, Summary: byte-identity, --full passthrough),
#         mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-retros-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-retros-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7 8 9; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
MUT=""; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT

# write_stub <exit_code> <output_text> — creates TMP/sweep-retros.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-retros.sh"
  chmod +x "$TMP/sweep-retros.sh"
  cp "$SUT" "$TMP/sweep-retros-hook.sh"
  chmod +x "$TMP/sweep-retros-hook.sh"
}

# 3. Operational failure (sweep exits non-zero) → "could not run" banner, NOT normal header.
write_stub 1 "sweep-retros: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'could not run\|error\|exit 1' \
  && ok "3 sweep failure (rc=1) → operational-failure banner emitted" \
  || no "3 sweep failure → expected 'could not run' banner (exit=$RC out=[$OUT])"

# 4. Success (sweep exits 0) → normal header present in output.
write_stub 0 "TARGET  demo  · 0 open retros"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'retro sweep\|§18' \
  && ok "4 success (rc=0) → normal retro header emitted" \
  || no "4 success → expected normal header (exit=$RC out=[$OUT])"

# 5. Failure banner uses singular "retro sweep" (not "retros sweep").
write_stub 1 "sweep-retros: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'retro sweep could not run' \
  && ok "5 failure banner wording: 'retro sweep could not run' (singular, not 'retros')" \
  || no "5 failure banner wording: expected 'retro sweep could not run' (exit=$RC out=[$OUT])"

# ---- Summary mode tests -----------------------------------------------------

# Helper: build a sweep stub with N PENDING rows + 2 absent targets.
_build_sweep_out() {
  local n_pending="$1"
  local i ep txt
  ep=1000  # base epoch for oldest-first ordering
  txt=""
  txt="${txt}INFO: corpus not found (absent-input): /targets/absent-a"$'\n'
  txt="${txt}INFO: corpus not found (absent-input): /targets/absent-b"$'\n'
  for i in $(seq 1 "$n_pending"); do
    txt="${txt}PENDING  /targets/t/retros/retro${i}.md"$'\n'
    txt="${txt}         target: /targets/t  ·  ~${i} proposed deltas  ·  status: pending  ·  age: ${i}d"$'\n'
    ep=$((ep + 86400))
  done
  txt="${txt}"$'\n'
  txt="${txt}Summary: ${n_pending} pending / $((n_pending + 3)) retros across targets."$'\n'
  txt="${txt}INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."$'\n'
  printf '%s' "$txt"
}

# Helper: extract additionalContext from jq-wrapped hook output (or pass through on fallback).
_hook_content() { printf '%s\n' "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || printf '%s\n' "$1"; }

# 6. Summary mode (default, 0 pending + absent targets): absent collapse line still prints.
#    A silent clean run is the defect — sentinel/collapse lines MUST appear.
write_stub 0 "$(_build_sweep_out 0)"
OUT6="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
_content6="$(_hook_content "$OUT6")"
<<<"$_content6" grep -qE 'INFO: 2 target\(s\) not traversed' \
  && ok "6 summary mode, 0 pending + 2 absent: absent collapse line present (no silent clean)" \
  || no "6 summary mode, 0 pending + 2 absent: absent collapse line MISSING"

# 7. Summary mode: absent collapse line says "run --full to list them" (not "see INFO lines above").
<<<"$_content6" grep -q 'run --full to list them' \
  && ok "7 summary mode: absent collapse line says 'run --full to list them'" \
  || no "7 summary mode: absent collapse line missing --full hint"

# 8. Summary mode with >5 pending: only 5 PENDING lines shown + "N more" message.
write_stub 0 "$(_build_sweep_out 8)"
OUT8="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
_content8="$(_hook_content "$OUT8")"
_cnt8="$(printf '%s\n' "$_content8" | grep -c '^PENDING')" || _cnt8=0
[ "$_cnt8" -eq 5 ] \
  && ok "8 summary mode, 8 pending: exactly 5 PENDING lines shown (got $_cnt8)" \
  || no "8 summary mode, 8 pending: expected 5 PENDING lines, got $_cnt8"

<<<"$_content8" grep -q 'and 3 more' \
  && ok "8b summary mode: '… and 3 more' message present" \
  || no "8b summary mode: '… and 3 more' message MISSING"

# 9. Summary: line is byte-identical in default (summary) mode and --full mode.
_sweep9_out="$(_build_sweep_out 7)"
write_stub 0 "$_sweep9_out"
OUT9_SUMM="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
OUT9_FULL="$(bash "$TMP/sweep-retros-hook.sh" --full 2>&1)"
_sum_summ="$(printf '%s\n' "$(_hook_content "$OUT9_SUMM")" | grep '^Summary:')"
_sum_full="$(printf '%s\n' "$(_hook_content "$OUT9_FULL")" | grep '^Summary:')"
[ "$_sum_summ" = "$_sum_full" ] \
  && ok "9 Summary: line byte-identical in summary and --full modes" \
  || no "9 Summary: line differs: summary=[$_sum_summ] full=[$_sum_full]"

# ---- Teeth (mutation proof) -------------------------------------------------
# --- mutation-control helpers (kit issues #943, #1299) ---------------------------------------------
# Every mutant is built as a COPY of the SUT under $MUT (a temp dir outside the live tree) by the shared
# lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or live-tree mutant and a dead sed
# stage; each control then asserts the GOOD verdict on the original AND the SPECIFIC BAD verdict on the
# mutant (exact rc on both sides: a crashing mutant is not teeth).
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
# mk_sed LABEL OUT EXPR...  build $OUT from $SUT with one sed stage per EXPR (mutant_chain refuses a dead
# stage); a refusal is counted as a failure here, the helper itself never touches the counters.
mk_sed(){
  local out="$2"
  mkdir -p "$(dirname "$out")"
  mutant_chain "$1" "$SUT" "$out" "${@:3}" || { fail=$((fail+1)); return 1; }
}
# tooth LABEL GOOD_RC BAD_RC MUTANT [--orig PATH] [--good-has RE] [--bad-lacks RE] [--bad-has RE] -- ARGV...
# Counting wrapper over the shared mutant_tooth (which prints its own PASS/FAIL line). The pre-migration
# local helper matched patterns case-insensitively, so MUTANT_TOOTH_ICASE keeps that behaviour exactly.
tooth(){
  if MUTANT_TOOTH_ICASE=1 mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
# hook_tooth LABEL GOOD_RC BAD_RC MUTANT [tooth opts] -- ARGV...   the hook locates its sweep stub next to
# itself, so the stub currently in $TMP (set by write_stub for this scenario) is copied beside the mutant;
# the ORIGINAL runs from $TMP's hook copy (also refreshed by write_stub).
hook_tooth(){
  local label="$1" grc="$2" brc="$3" mut="$4"; shift 4
  cp "$TMP/sweep-retros.sh" "$(dirname "$mut")/sweep-retros.sh"
  tooth "$label" "$grc" "$brc" "$mut" --orig "$TMP/sweep-retros-hook.sh" "$@"
}

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  echo "-- teeth: hook must go red when rc-check is neutered --"
  H='sweep-retros-hook.sh'

  # Tooth A: mutant hook never checks rc — always takes the success path. Test 3 must go RED.
  write_stub 1 "sweep-retros: cannot find TARGETS.md"
  mk_sed "teeth A" "$MUT/A/$H" 's/if \[ "\$rc" -ne 0 \]/if false/' \
    && hook_tooth "teeth A: rc-neutered mutant omits failure banner → test 3 would catch it (RED)" 0 0 "$MUT/A/$H" \
         --good-has 'retro sweep could not run' --bad-lacks 'could not run|exit 1' \
         --bad-has 'Research-SDD retro sweep \(supervisor project\)' -- bash @SUT@

  # Tooth B: revert failure-banner wording to "retros sweep" → test 5 goes RED.
  write_stub 1 "sweep-retros: cannot find TARGETS.md"
  mk_sed "teeth B" "$MUT/B/$H" 's/retro sweep could not run/retros sweep could not run/' \
    && hook_tooth "teeth B: reverted to 'retros sweep' mutant → test 5 would catch it (RED)" 0 0 "$MUT/B/$H" \
         --good-has 'retro sweep could not run' --bad-lacks 'retro sweep could not run' \
         --bad-has 'retros sweep could not run' -- bash @SUT@

  # Tooth C: mutant drops the absent-collapse line (ABSENT-COLLAPSE-PRINT) → test 6 goes RED.
  echo "-- teeth C: absent-collapse line dropped → test 6 must catch it --"
  write_stub 0 "$(_build_sweep_out 0)"
  mk_sed "teeth C" "$MUT/C/$H" 's/print; next  # ABSENT-COLLAPSE-PRINT/next/' \
    && hook_tooth "teeth C: absent-collapse-drop mutant suppresses collapse line → test 6 would catch it (RED)" 0 0 "$MUT/C/$H" \
         --good-has 'INFO: 2 target\(s\) not traversed' --bad-lacks 'INFO: 2 target\(s\) not traversed' \
         --bad-has 'Summary: 0 pending' -- bash @SUT@

  # Tooth D: mutant alters the Summary: line in summary mode only → test 9 byte-equality goes RED.
  # The argv extracts the Summary: line in summary mode and in --full mode and prints SAME, or DIFFER
  # plus the summary-mode line, or EMPTY when either extraction is empty (a crashed mutant is not teeth).
  echo "-- teeth D: Summary: line mutated in summary mode → test 9 must catch it --"
  write_stub 0 "$(_build_sweep_out 7)"
  mk_sed "teeth D" "$MUT/D/$H" 's/print; next  # SUMMARY-LINE-PRINT/$0 = $0 " MUTATED"; print; next/' \
    && hook_tooth "teeth D: Summary-altered mutant → summary mode differs from --full → test 9 would catch it (RED)" 0 0 "$MUT/D/$H" \
         --good-has '^SAME$' --bad-lacks '^SAME$' --bad-has 'MUTATED' -- \
         bash -c 'c(){ o="$(bash "$1" ${2:-} 2>&1)"; j="$(printf "%s\n" "$o" | jq -r ".hookSpecificOutput.additionalContext" 2>/dev/null)" || j="$o"; printf "%s\n" "$j" | grep "^Summary:"; }
                  a="$(c "$1")"; b="$(c "$1" --full)"; if [ -z "$a" ] || [ -z "$b" ]; then echo EMPTY; elif [ "$a" = "$b" ]; then echo SAME; else echo DIFFER; printf "%s\n" "$a"; fi' _ @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
