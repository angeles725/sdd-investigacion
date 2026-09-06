#!/usr/bin/env bash
# retro-grammar.test.sh — regression harness for lib/retro-grammar.sh (#483 U18).
#
# Tests the retro_grammar_delta_info shared grammar function directly, and
# proves the both-consumers-flip invariant: changing one deprecated-alias regex
# in the lib must flip BOTH sweep-retros.sh (delta count) AND verify-retro.sh
# (conformance verdict).
#
# Usage: retro-grammar.test.sh [--prove-teeth]
# Exit: 0 = all held · 1 = regression · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RG_LIB="$HERE/../lib/retro-grammar.sh"
SWEEP_SUT="$HERE/../sweep-retros.sh"
VERIFY_SUT="$HERE/../verify-retro.sh"
LIB_STATUS="$HERE/../lib/retro-status.sh"
LIB_TP="$HERE/../lib/target-paths.sh"
LIB_BF="$HERE/../lib/block-files.sh"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

[ -f "$RG_LIB" ]     || { echo "FATAL: retro-grammar lib not found: $RG_LIB" >&2; exit 2; }
[ -f "$SWEEP_SUT" ]  || { echo "FATAL: sweep-retros SUT not found: $SWEEP_SUT" >&2; exit 2; }
[ -f "$VERIFY_SUT" ] || { echo "FATAL: verify-retro SUT not found: $VERIFY_SUT" >&2; exit 2; }
[ -f "$LIB_STATUS" ] || { echo "FATAL: retro-status lib not found: $LIB_STATUS" >&2; exit 2; }
[ -f "$LIB_TP" ]     || { echo "FATAL: target-paths lib not found: $LIB_TP" >&2; exit 2; }
[ -f "$LIB_BF" ]     || { echo "FATAL: block-files lib not found: $LIB_BF" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()  { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== retro-grammar.test.sh (lib: $(basename "$RG_LIB")) =="

# ── Source the lib and set up direct-call helpers ──────────────────────────────
# shellcheck source=../lib/retro-grammar.sh
. "$RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  || { echo "FATAL: retro_grammar_delta_info not defined after sourcing $RG_LIB" >&2; exit 2; }

# rgi_field <file> <field-index 1..5>  — call retro_grammar_delta_info and extract one field
# Fields: 1=<found>:<form>:<count>  2=depr_h  3=unrec_found  4=unrec_data  5=unrec_heading
rgi() { retro_grammar_delta_info "${1:-}"; }
rgi_first() {
  local raw; raw=$(rgi "$1")
  printf '%s' "${raw%%$'\001'*}"
}

# ── Fixture writers ────────────────────────────────────────────────────────────
mkfix_canonical() {
  # mkfix_canonical <file> <nrows> — write a retro with canonical heading + N data rows
  local f="$1" n="$2" i=0
  { printf '<!-- review-status: pending -->\n# Retro\n\n'
    printf '## Proposed kit deltas\n\n'
    printf '| # | change | target | evidence | type | prio |\n|---|---|---|---|---|---|\n'
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '| %d | ch%d | f.md | B%03d | new | H |\n' "$i" "$i" "$i"; done
  } > "$f"
}
mkfix_deprecated() {
  # mkfix_deprecated <file> <nrows> — retro with deprecated "## Summary of proposed delta" heading
  local f="$1" n="$2" i=0
  { printf '<!-- review-status: pending -->\n# Retro\n\n'
    printf '## Summary of proposed delta\n\n'
    printf '| # | change | target | evidence | type | prio |\n|---|---|---|---|---|---|\n'
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '| %d | ch%d | f.md | B%03d | new | H |\n' "$i" "$i" "$i"; done
  } > "$f"
}
mkfix_h3d() {
  # mkfix_h3d <file> <nentries> — retro with ### D1 — sub-headings (form-2)
  local f="$1" n="$2" i=0
  { printf '<!-- review-status: pending -->\n# Retro\n\n'
    printf '## Proposed kit deltas\n\n'
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '### D%d — entry %d\n\nsome prose\n\n' "$i" "$i"; done
  } > "$f"
}
mkfix_form3() {
  # mkfix_form3 <file> <n> — retro with ## Delta Wn — headings (form-3)
  local f="$1" n="$2" i=0
  { printf '<!-- review-status: pending -->\n# Retro\n\n'
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '## Delta W%d — item %d\n\nprose\n\n' "$i" "$i"; done
  } > "$f"
}
mkfix_empty() {
  # mkfix_empty <file> — canonical heading with zero data rows
  local f="$1"
  printf '<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n' > "$f"
}
mkfix_no_section() {
  # mkfix_no_section <file> — no delta heading at all
  local f="$1"
  printf '<!-- review-status: pending -->\n# Retro\n\nsome prose\n' > "$f"
}
mkfix_absent() {
  # mkfix_absent — no file at all; rgi should handle gracefully
  true
}

# ── Unit tests: retro_grammar_delta_info output format ────────────────────────

# T1: canonical heading with 3 data rows → found=1, form=1, count=3
_f="$ROOT/t1.md"; mkfix_canonical "$_f" 3
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "1:1:3" ] && ok "T1: canonical 3-row → 1:1:3" "[$_out]" \
  || no "T1: canonical 3-row → expected 1:1:3" "got=[$_out]"

# T2: deprecated heading with 2 data rows → found=1, form=1, count=2, depr_h non-empty
_f="$ROOT/t2.md"; mkfix_deprecated "$_f" 2
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
_rest="${_out#*$'\001'}"; _dh="${_rest%%$'\001'*}"
[ "$_ffc" = "1:1:2" ] && [ -n "$_dh" ] \
  && ok "T2: deprecated heading 2-row → 1:1:2, depr_h non-empty" "[$_dh]" \
  || no "T2: deprecated heading 2-row → expected 1:1:2 + depr_h" "out=[$_out]"

# T3: form-2 (### D1 —) with 2 entries → found=1, form=2, count=2
_f="$ROOT/t3.md"; mkfix_h3d "$_f" 2
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "1:2:2" ] && ok "T3: form-2 h3d 2 entries → 1:2:2" "[$_out]" \
  || no "T3: form-2 h3d 2 entries → expected 1:2:2" "got=[$_out]"

# T4: form-3 (## Delta W1 —) with 2 headings → found=0, form=3, count=2
_f="$ROOT/t4.md"; mkfix_form3 "$_f" 2
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "0:3:2" ] && ok "T4: form-3 2 headings → 0:3:2" "[$_out]" \
  || no "T4: form-3 2 headings → expected 0:3:2" "got=[$_out]"

# T5: canonical heading, zero data rows → found=1, form=w, count=0
_f="$ROOT/t5.md"; mkfix_empty "$_f"
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "1:w:0" ] && ok "T5: canonical heading + zero rows → 1:w:0" "[$_out]" \
  || no "T5: canonical heading + zero rows → expected 1:w:0" "got=[$_out]"

# T6: no delta section at all → found=0, form=n, count=0
_f="$ROOT/t6.md"; mkfix_no_section "$_f"
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "0:n:0" ] && ok "T6: no section → 0:n:0" "[$_out]" \
  || no "T6: no section → expected 0:n:0" "got=[$_out]"

# T7: absent file → returns 0:n:0 (anti-silent-zero: no crash)
_out=$(retro_grammar_delta_info "/tmp/__rg_test_nonexistent__.md" 2>/dev/null); _ffc="${_out%%$'\001'*}"
[ "$_ffc" = "0:n:0" ] && ok "T7: absent file → 0:n:0 (no crash)" "[$_out]" \
  || no "T7: absent file → expected 0:n:0" "got=[$_out]"

# T8: unrecognised-heading Rule 1 (## deltas proposed) sets unrec_found=1
_f="$ROOT/t8.md"
printf '<!-- review-status: pending -->\n# Retro\n\n## deltas proposed\n\nprose\n' > "$_f"
_out=$(rgi "$_f")
_rest="${_out#*$'\001'}"; _rest="${_rest#*$'\001'}"; _uf="${_rest%%$'\001'*}"
[ "$_uf" = "1" ] && ok "T8: unrecognised Rule 1 (## deltas) → unrec_found=1" "[$_out]" \
  || no "T8: unrecognised Rule 1 → expected unrec_found=1" "got=[$_out]"

# T9: idempotent sourcing — sourcing the lib a second time must not re-define the function
# (the if ! declare -F guard prevents it). We check by calling the function after double-source.
# shellcheck source=../lib/retro-grammar.sh
. "$RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  && ok "T9: double-source idempotent — function still defined after second source" \
  || no "T9: double-source idempotent — function GONE after second source"

echo ""
echo "== $pass passed · $fail failed =="
echo ""

# ── TEETH (--prove-teeth): both-consumers-flip mutant ────────────────────────
if [ "${1:-}" != "--prove-teeth" ]; then
  if [ "$fail" -gt 0 ]; then exit 1; fi
  exit 0
fi

echo "== TEETH: both-consumers-flip mutant =="

# Build a shared sandbox kit: sweep-retros + verify-retro share the same lib/retro-grammar.sh.
# A single lib mutation must flip BOTH consumers — proving behavioral sharing is real and complete.
_kit="$ROOT/flip-kit"
mkdir -p "$_kit/toolbelt/lib"
cp "$SWEEP_SUT"  "$_kit/toolbelt/sweep-retros.sh"
cp "$VERIFY_SUT" "$_kit/toolbelt/verify-retro.sh"
cp "$LIB_STATUS" "$_kit/toolbelt/lib/retro-status.sh"
cp "$LIB_TP"     "$_kit/toolbelt/lib/target-paths.sh"
cp "$LIB_BF"     "$_kit/toolbelt/lib/block-files.sh"
cp "$RG_LIB"     "$_kit/toolbelt/lib/retro-grammar.sh"

# Fixture retro: uses ONLY the deprecated "## Summary of proposed delta" heading (not canonical).
# With the real lib: sweep finds it (deprecated, ~2 deltas); verify exits 0 (deprecated but conforming).
# After mutating the first deprecated alias: neither consumer recognises the heading any more.
_tgt="$ROOT/flip-target"; mkdir -p "$_tgt/retros"
{ printf '<!-- review-status: pending -->\n# Retro — flip-target · none · 2026-01-01 · Research-SDD self-retrospective\n\n'
  printf '## Summary of proposed delta\n\n'
  printf '| # | Proposed change | Target | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf '| 1 | change A | file.md | B001 | new | HIGH |\n'
  printf '| 2 | change B | file.md | B002 | refinement | MEDIUM |\n'
} > "$_tgt/retros/depr.md"

# TARGETS.md for sweep-retros
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | flip-target | `%s` |\n' "$_tgt"
} > "$_kit/TARGETS.md"

# ── Baseline: run both consumers with the ORIGINAL lib ──────────────────────
_sw_base="$("$BASH_BIN" "$_kit/toolbelt/sweep-retros.sh" 2>&1)"; _sw_rc_base=$?
_vr_base="$("$BASH_BIN" "$_kit/toolbelt/verify-retro.sh" "$_tgt/retros/depr.md" 2>&1)"; _vr_rc_base=$?

# Verify baselines are as expected (fixture sanity)
echo "-- baseline sanity check --"
if grep -q 'proposed deltas' <<<"$_sw_base" && ! grep -q 'no delta section found' <<<"$_sw_base"; then
  ok "FLIP-BASE-SW: sweep-retros finds delta section with original lib" "(depr heading recognised)"
else
  no "FLIP-BASE-SW: sweep-retros must find delta section baseline" "out=[$_sw_base]"
fi
if [ "$_vr_rc_base" = 0 ]; then
  ok "FLIP-BASE-VR: verify-retro exits 0 (conforming) with original lib" "(depr heading recognised)"
else
  no "FLIP-BASE-VR: verify-retro must exit 0 baseline" "rc=$_vr_rc_base out=[$_vr_base]"
fi

# ── Mutation: change the first deprecated alias so the fixture heading no longer matches ──
# RSDD_RETRO_GRAMMAR_DEPR_ANCHOR is the sentinel comment; mutate the line immediately after it.
# Replacement: change "^## summary of proposed delta" to a token that never matches real headings.
_lib_content="$(cat "$_kit/toolbelt/lib/retro-grammar.sh")"
_depr_anchor='low ~ /^## summary of proposed delta/'
if [[ "$_lib_content" != *"$_depr_anchor"* ]]; then
  no "FLIP-MUTANT: locate deprecated-alias anchor in lib" "RSDD_RETRO_GRAMMAR_DEPR_ANCHOR line not found — lib drifted?"
else
  _mutated_lib="${_lib_content/"$_depr_anchor"/low ~ \/^## summary of ZZZMUTATED\/}"
  printf '%s\n' "$_mutated_lib" > "$_kit/toolbelt/lib/retro-grammar.sh"

  # ── Mutant run: both consumers must change behavior ──────────────────────
  echo "-- both-consumers-flip mutant run --"
  _sw_mut="$("$BASH_BIN" "$_kit/toolbelt/sweep-retros.sh" 2>&1)"; _sw_rc_mut=$?
  _vr_mut="$("$BASH_BIN" "$_kit/toolbelt/verify-retro.sh" "$_tgt/retros/depr.md" 2>&1)"; _vr_rc_mut=$?

  # sweep-retros must no longer count a delta section (heading gone → 'no delta section found' or ~0)
  _sw_flipped=0
  if grep -q 'no delta section found' <<<"$_sw_mut" || grep -q '~0 proposed deltas' <<<"$_sw_mut"; then
    _sw_flipped=1
  elif ! grep -q '~2 proposed deltas' <<<"$_sw_mut" && ! grep -q 'proposed deltas' <<<"$_sw_mut"; then
    _sw_flipped=1
  fi
  [ "$_sw_flipped" = 1 ] \
    && ok "FLIP-SW: mutant lib flips sweep-retros (delta section gone/zero)" "(both-consumers-flip has teeth for sweep)" \
    || no "FLIP-SW: mutant lib must flip sweep-retros delta count" "base=[$_sw_base] mut=[$_sw_mut]"

  # verify-retro must change: baseline was 0 (conforming), mutant must be 1 (FAIL)
  [ "$_vr_rc_mut" = 1 ] \
    && ok "FLIP-VR: mutant lib flips verify-retro (exits 1 = FAIL)" "(both-consumers-flip has teeth for verify)" \
    || no "FLIP-VR: mutant lib must flip verify-retro to exit 1" "base-rc=$_vr_rc_base mut-rc=$_vr_rc_mut mut=[$_vr_mut]"
fi

echo ""
echo "== $pass passed · $fail failed =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
