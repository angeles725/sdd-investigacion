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
printf '%s\n' "$OUT" | grep -qi 'unrecorded' \
  && printf '%s\n' "$OUT" | grep -qi 'Summary' \
  && ok "4 unrecorded > 0 → emits summary line" \
  || no "4 unrecorded > 0 → expected summary in output (exit=$RC out=[$OUT])"

# 5. Operational failure (sweep exits non-zero) → error banner, not silence.
write_stub 1 "sweep-tools: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "5 sweep failure (rc=1) → error banner emitted" \
  || no "5 sweep failure → expected error banner (exit=$RC out=[$OUT])"

# 6. Anti-silent-zero: sweep exits 0 but emits no Summary line → warning surfaced.
write_stub 0 "TARGET  demo"$'\n'"        no tools directory"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'missing summary\|unexpected' \
  && ok "6 missing Summary line → anti-silent-zero warning emitted" \
  || no "6 missing Summary line → expected warning, got exit=$RC out=[$OUT]"

# 7. PARTIAL WARN passthrough: WARN line from sweep included when unrecorded > 0.
write_stub 0 "$(printf 'Summary: 1 tool(s) across 2 target(s) · 0 recorded · 1 unrecorded.\nWARN: 1 target(s) skipped — truncated path; sweep is PARTIAL: some-target')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -q 'WARN' \
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
printf '%s\n' "$OUT_STH8" | grep -qiE 'WARN-line extraction failed|grep exit' \
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
   && printf '%s\n' "$OUT" | grep -q 'INFO:.*not traversed'; then
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
   && printf '%s\n' "$OUT" | grep -q 'unrecorded' \
   && printf '%s\n' "$OUT" | grep -q 'INFO:.*not traversed'; then
  ok "10 unrecorded>0 AND absent → both surfaced in output" "(exit $RC)"
else
  no "10 unrecorded>0 AND absent → expected both unrecorded summary and INFO line, got exit=$RC out=[$OUT]"
fi

# ---- Teeth (mutation proof) -------------------------------------------------
# --- mutation-control helpers (kit issues #943, #1299) ---------------------------------------------
# TODO(#1299): replace with shared lib/mutant.sh helpers once promoted
# Every mutant is built as a COPY of the SUT under $MUT (a temp dir outside the live tree) by
# lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or live-tree mutant; each
# control then asserts the GOOD verdict on the original AND the SPECIFIC BAD verdict on the mutant.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_sed >/dev/null 2>&1 && typeset -f mutant_verify >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_sed/mutant_verify ($HERE/lib/mutant.sh)" >&2; exit 2; }
# mk_sed LABEL OUT EXPR...  build $OUT from $SUT with one sed stage per EXPR. Each stage must change
# the original ON ITS OWN: a chain whose first stage applies would otherwise hide a later stage that
# matches nothing (a silent no-op) behind a mutant that merely differs.
mk_sed(){
  local label="$1" out="$2" e rc err; shift 2
  local -a args=()
  for e in "$@"; do
    if sed -e "$e" "$SUT" | cmp -s - "$SUT"; then
      no "$label: sed stage matches nothing in the original (silent no-op) :: [$e]"; return 1
    fi
    args+=(-e "$e")
  done
  mkdir -p "$(dirname "$out")"
  err="$(mutant_sed "$SUT" "$out" "${args[@]}" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { no "$label: mutant refused by lib/mutant.sh (rc=$rc) :: $err"; return 1; }
}
# tooth LABEL GOOD_RC BAD_RC MUTANT [--orig PATH] [--good-has RE] [--bad-lacks RE] [--bad-has RE] -- ARGV...
# Runs ARGV twice, '@SUT@' replaced by the original ($SUT unless --orig), then by the mutant. PASS only when the original
# returns exactly GOOD_RC (and its output matches --good-has) AND the mutant returns exactly BAD_RC
# (and its output no longer matches --bad-lacks, and matches --bad-has): a crashing mutant is not teeth.
tooth(){
  local label="$1" grc="$2" brc="$3" mut="$4" gpat="" bpat="" bhas="" orig="$SUT" a gout mout grc_a mrc_a why=""; shift 4
  while [ "${1:-}" != -- ]; do
    case "${1:-}" in
      --orig) orig="$2" ;; --good-has) gpat="$2" ;; --bad-lacks) bpat="$2" ;; --bad-has) bhas="$2" ;;
      *) no "$label: tooth() bad option '${1:-}'"; return 1 ;;
    esac; shift 2
  done; shift
  local -a gc=() mc=()
  for a in "$@"; do gc+=("${a//@SUT@/"$orig"}"); mc+=("${a//@SUT@/"$mut"}"); done
  gout="$("${gc[@]}" 2>&1)"; grc_a=$?
  mout="$("${mc[@]}" 2>&1)"; mrc_a=$?
  [ "$grc_a" = "$grc" ] || why="original rc=$grc_a (want $grc)"
  if [ -n "$gpat" ] && ! grep -qiE -- "$gpat" <<<"$gout"; then why="$why; original output lacks /$gpat/"; fi
  [ "$mrc_a" = "$brc" ] || why="$why; mutant rc=$mrc_a (want $brc)"
  if [ -n "$bpat" ] && grep -qiE -- "$bpat" <<<"$mout"; then why="$why; mutant output still matches /$bpat/"; fi
  if [ -n "$bhas" ] && ! grep -qiE -- "$bhas" <<<"$mout"; then why="$why; mutant output lacks /$bhas/"; fi
  if [ -z "$why" ]; then ok "$label [original rc=$grc → mutant rc=$brc]"
  else no "$label — THEATER:$why"; fi
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

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
