#!/usr/bin/env bash
# sweep-tools-hook.test.sh — red-first harness for sweep-tools-hook.sh.
# Covers: existence, silent-when-clean, surface-when-unrecorded, error-when-failed,
# anti-silent-zero (missing Summary line), PARTIAL WARN passthrough, and mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-tools-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-tools-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 1
fi

# ---- Temp workspace ---------------------------------------------------------
MUT=""; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT

# write_stub <exit_code> <output_text> — creates TMP/sweep-tools.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-tools.sh"
  chmod +x "$TMP/sweep-tools.sh"
  cp "$SUT" "$TMP/sweep-tools-hook.sh"
  chmod +x "$TMP/sweep-tools-hook.sh"
}

# 3. Silent when all tools are ledgered (0 unrecorded).
write_stub 0 "Summary: 5 tool(s) across 3 target(s) · 5 recorded · 0 unrecorded."
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] \
  && ok "3 all-ledgered (0 unrecorded) → silent, exit 0" \
  || no "3 all-ledgered → expected silence, got exit=$RC out=[$OUT]"

# 4. Emits summary when unrecorded > 0.
write_stub 0 "$(printf 'TARGET  demo\n        tools: 3 found\n        recorded (T-rows): 1  ·  unrecorded: 2  ·  no retro has a tools table\n\nSummary: 3 tool(s) across 1 target(s) · 1 recorded · 2 unrecorded.')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'unrecorded' \
  && <<<"$OUT" grep -qi 'Summary' \
  && ok "4 unrecorded > 0 → emits summary line" \
  || { no "4 unrecorded > 0 → expected summary in output (exit=$RC out=[$OUT])"
       # Kit issue #1349: seen once inside an aggregate run, never reproduced standalone. Record the stub
       # inputs the hook actually ran against (a "could not run" banner here would point at an exec race
       # on the freshly written stub, e.g. ETXTBSY, rather than at the hook's parsing).
       printf '        stub: %s | hook: %s | stub-out: [%s]\n' \
         "$(ls -l "$TMP/sweep-tools.sh" 2>&1)" "$(ls -l "$TMP/sweep-tools-hook.sh" 2>&1)" "$(cat "$TMP/stub-out.txt" 2>&1)"
       printf '        jq=%s TMPDIR=%s\n' "$(command -v jq 2>&1 || echo absent)" "${TMPDIR:-unset}"; }

# 5. Operational failure (sweep exits non-zero) → error banner, not silence.
write_stub 1 "sweep-tools: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'could not run\|error\|exit 1' \
  && ok "5 sweep failure (rc=1) → error banner emitted" \
  || no "5 sweep failure → expected error banner (exit=$RC out=[$OUT])"

# 6. Anti-silent-zero: sweep exits 0 but emits no Summary line → warning surfaced.
write_stub 0 "TARGET  demo"$'\n'"        no tools directory"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'missing summary\|unexpected' \
  && ok "6 missing Summary line → anti-silent-zero warning emitted" \
  || no "6 missing Summary line → expected warning, got exit=$RC out=[$OUT]"

# 7. PARTIAL WARN passthrough: WARN line from sweep included when unrecorded > 0.
write_stub 0 "$(printf 'Summary: 1 tool(s) across 2 target(s) · 0 recorded · 1 unrecorded.\nWARN: 1 target(s) skipped — truncated path; sweep is PARTIAL: some-target')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -q 'WARN' \
  && ok "7 PARTIAL WARN included when unrecorded > 0" \
  || no "7 PARTIAL WARN → expected WARN in output (exit=$RC out=[$OUT])"

# 8. WARN-line extraction grep error (exit ≥2) must append failure notice; never silently empty warn_line.
#    Stubs grep so any call for '^WARN:' (the extraction call in the hook) exits 2.
_sth_real_grep=/usr/bin/grep
_stub_sth8="$TMP/stub-bin-sth8"; mkdir -p "$_stub_sth8"
cat > "$_stub_sth8/grep" << STUB_STH8
#!/usr/bin/env bash
[ "\$1" = '^WARN:' ] && exit 2
exec "${_sth_real_grep}" "\$@"
STUB_STH8
chmod +x "$_stub_sth8/grep"
write_stub 0 "$(printf 'Summary: 1 tool(s) across 1 target(s) · 0 recorded · 1 unrecorded.')"
OUT_STH8="$(PATH="$_stub_sth8:$PATH" bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC_STH8=$?
<<<"$OUT_STH8" grep -qiE 'WARN-line extraction failed|grep exit' \
  && ok "8 WARN-line extraction grep exit-2 → failure notice in output" \
  || no "8 WARN-line extraction grep exit-2 not reported (exit=$RC_STH8 out=[$OUT_STH8])"

# 9. Targets not traversed (absent_targets > 0), 0 unrecorded → must NOT stay silent.
#    Fresh machine scenario: RESEARCH_HOME points nowhere, so no targets exist on disk.
#    sweep-tools.sh reports Summary with 0 unrecorded BUT also an INFO not-traversed line.
#    The hook must surface the INFO instead of exiting silently.
#    Assertion uses `INFO:.*not traversed` (not just `not traversed`) so the header text
#    "(targets not traversed)" cannot satisfy the grep in place of the actual INFO line.
write_stub 0 "$(printf 'Summary: 0 tool(s) across 0 target(s) · 0 recorded (retro) · 0 recorded (ledger) · 0 unrecorded.\nINFO: 34 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
if [ -n "$OUT" ] && [ "$RC" -eq 0 ] \
   && <<<"$OUT" grep -q 'INFO:.*not traversed'; then
  ok "9 absent targets (0 unrecorded) → NOT silent, INFO line surfaced" "(exit $RC)"
else
  no "9 absent targets → expected INFO:.*not traversed in output, got exit=$RC out=[$OUT]"
fi

# 10. Unrecorded tools AND absent targets → both must appear in output.
#     sweep-tools.sh reports unrecorded count > 0 AND an INFO not-traversed line.
#     The hook must include both in its output (neither may be silently dropped).
write_stub 0 "$(printf 'Summary: 5 tool(s) across 2 target(s) · 0 recorded (retro) · 0 recorded (ledger) · 5 unrecorded.\nINFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
if [ -n "$OUT" ] && [ "$RC" -eq 0 ] \
   && <<<"$OUT" grep -q 'unrecorded' \
   && <<<"$OUT" grep -q 'INFO:.*not traversed'; then
  ok "10 unrecorded>0 AND absent → both surfaced in output" "(exit $RC)"
else
  no "10 unrecorded>0 AND absent → expected both unrecorded summary and INFO line, got exit=$RC out=[$OUT]"
fi

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
  cp "$TMP/sweep-tools.sh" "$(dirname "$mut")/sweep-tools.sh"
  tooth "$label" "$grc" "$brc" "$mut" --orig "$TMP/sweep-tools-hook.sh" "$@"
}

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  H='sweep-tools-hook.sh'
  echo "-- teeth: hook must go red when silence is broken --"

  # Tooth A: mutant hook always exits 0 without output (ignores both unrecorded and absent).
  # Test 4 (unrecorded > 0 → emits summary) must catch this and go RED. The sentinel is REQUIRED:
  # the old fallback sed (a literal-form substitution used when the sentinel was missing) is dropped,
  # because a stage that matches nothing used to leave the mutant byte-identical to the original.
  write_stub 0 "$(printf 'Summary: 3 tool(s) across 1 target(s) · 1 recorded · 2 unrecorded.')"
  mk_sed "teeth A" "$MUT/A/$H" '/# STH-SILENT-EXIT/ s/.*/exit 0  # STH-SILENT-EXIT (teeth-A mutant)/' \
    && hook_tooth "teeth A: always-silent mutant produces no output → test 4 would catch it (RED)" 0 0 "$MUT/A/$H" \
         --good-has 'unrecorded' --bad-lacks '.' -- bash @SUT@

  # Tooth B: neutralize _sth_warn_rc so a WARN-line extraction error passes silently → test 8 goes red.
  # The grep stub (exit 2 on '^WARN:') is injected through PATH for BOTH runs.
  echo "-- teeth B: neutralize _sth_warn_rc; extraction exit-2 must pass silently → test 8 goes red --"
  write_stub 0 "$(printf 'Summary: 1 tool(s) across 1 target(s) · 0 recorded · 1 unrecorded.')"
  mk_sed "teeth B" "$MUT/B/$H" 's/_sth_warn_rc=\$?/_sth_warn_rc=0/' \
    && hook_tooth "teeth B: rc-zeroed mutant passes silently — extraction guard has teeth" 0 0 "$MUT/B/$H" \
         --good-has 'WARN-line extraction failed|grep exit' --bad-lacks 'WARN-line extraction failed|grep exit' \
         --bad-has 'unrecorded' -- env "PATH=$_stub_sth8:$PATH" bash @SUT@

  # Tooth C: remove the absent-target check from the silent-exit condition so the hook stays silent
  # when targets are absent but unrecorded=0. Test 9 must go RED. Literal sed:
  # the SUT's STH-ABSENT-CHECK marker sits on the COMMENT line above the condition, so the old
  # '/# STH-ABSENT-CHECK/ s///' branch could never match (it was dead; only the fallback ever ran).
  echo "-- teeth C: remove absent-target check; absent-but-0-unrecorded fixture must become silent → test 9 RED --"
  write_stub 0 "$(printf 'Summary: 0 tool(s) across 0 target(s) · 0 recorded (retro) · 0 recorded (ledger) · 0 unrecorded.\nINFO: 34 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.')"
  mk_sed "teeth C" "$MUT/C/$H" 's/ && \[ -z "\$info_absent" \]//' \
    && hook_tooth "teeth C: absent-check removed → absent fixture becomes silent (test 9 has teeth)" 0 0 "$MUT/C/$H" \
         --good-has 'INFO:.*not traversed' --bad-lacks '.' -- bash @SUT@

  # Tooth D: zero _sth_info_absent_out in the unrecorded branch; the unrecorded+absent fixture must
  # keep the summary but lose the INFO line → test 10's INFO assertion goes RED.
  echo "-- teeth D: zero _sth_info_absent_out; unrecorded+absent fixture must lose INFO line → test 10 RED --"
  write_stub 0 "$(printf 'Summary: 5 tool(s) across 2 target(s) · 0 recorded (retro) · 0 recorded (ledger) · 5 unrecorded.\nINFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.')"
  mk_sed "teeth D" "$MUT/D/$H" 's|_sth_info_absent_out=".*"|_sth_info_absent_out=""|' \
    && hook_tooth "teeth D: _sth_info_absent_out zeroed → INFO gone, unrecorded still present (test 10 has teeth)" 0 0 "$MUT/D/$H" \
         --good-has 'INFO:.*not traversed' --bad-lacks 'INFO:.*not traversed' \
         --bad-has 'unrecorded' -- bash @SUT@
fi

# Kit issue #1349 — pipefail + early-terminating consumer. Under `set -o pipefail`, a producer piped into `grep -q`
# fails whenever grep -q exits on its first match before printf has finished writing (SIGPIPE, rc 141): a
# PASSING assertion reads as a failure, only under load (the failure output itself contained the expected text).
# Assertions here use a here-string (`<<<"$v" grep -q PAT`) instead. This self-lint keeps the idiom out.
_pf_re='\| *grep +-[a-zA-Z]*q'
_pf_self="${BASH_SOURCE[0]}"
_pf_n="$(grep -cE -- "$_pf_re" "$_pf_self")"; _pf_rc=$?
if [ "$_pf_rc" -ge 2 ]; then no "#1349 lint: could not read $_pf_self (grep exit $_pf_rc)"
elif [ "${_pf_n:-0}" -eq 0 ]; then ok "#1349 lint: no 'pipe-into-grep-q' (pipefail SIGPIPE race) idiom in this suite"
else no "#1349 lint: $_pf_n 'pipe-into-grep-q' site(s) — use <<<\"\$v\" grep -q: $(grep -nE -- "$_pf_re" "$_pf_self" | cut -d: -f1 | head -20 | tr '\n' ' ')"; fi
# Detector self-check (the lint must be able to see the idiom it forbids).
if [ "$(printf 'x | %s -q y\n' grep | grep -cE -- "$_pf_re")" = "1" ]; then ok "#1349 lint: detector flags a synthetic 'pipe-into-grep-q' line"
else no "#1349 lint: detector missed a synthetic 'pipe-into-grep-q' line — the lint is THEATER"; fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
