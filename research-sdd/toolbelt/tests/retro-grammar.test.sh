#!/usr/bin/env bash
# retro-grammar.test.sh — regression harness for lib/retro-grammar.sh (#483 U18, #903).
#
# Tests the retro_grammar_delta_info shared grammar function directly, proves the
# both-consumers-flip invariant, and guards two structural concerns (#903):
#   ZSH-GUARD: typeset -f idempotency guard must define the function under zsh (not just bash)
#   RETRO-TRAP: research-sdd/retros/ must not exist (kit retros belong in top-level retros/)
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
ok()   { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-60s %s\n' "$1" "${2:-}"; }

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

# T10: Spanish canonical alias "## PROPUESTA de deltas al kit" (kit issue #1111) — accepted as
# canonical (not deprecated: no migration WARN), real fleet form (Pancaddia corpus retro).
_f="$ROOT/t10.md"
{ printf '<!-- review-status: pending -->\n# Retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
  printf '| # | change | target | evidence | type | prio |\n|---|---|---|---|---|---|\n'
  printf '| 1 | ch1 | f.md | B001 | new | H |\n'
} > "$_f"
_out=$(rgi "$_f"); _ffc="${_out%%$'\001'*}"
_rest="${_out#*$'\001'}"; _dh="${_rest%%$'\001'*}"
[ "$_ffc" = "1:1:1" ] && [ -z "$_dh" ] \
  && ok "T10: Spanish alias 'PROPUESTA de deltas al kit' 1-row → 1:1:1, no depr WARN" "[$_out]" \
  || no "T10: Spanish alias → expected 1:1:1 + empty depr_h" "got=[$_out]"

# T11: hyphenated "kit-delta" mid-heading (## B. Campaign-8 kit-delta backlog, real fleet form,
# niagara-research retro) sets unrec_found=1 — Rule 2 widened to accept '-' as well as ' '.
_f="$ROOT/t11.md"
printf '<!-- review-status: pending -->\n# Retro\n\n## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nprose\n' > "$_f"
_out=$(rgi "$_f")
_rest="${_out#*$'\001'}"; _rest="${_rest#*$'\001'}"; _uf="${_rest%%$'\001'*}"
[ "$_uf" = "1" ] && ok "T11: hyphenated 'kit-delta' mid-heading → unrec_found=1" "[$_out]" \
  || no "T11: hyphenated 'kit-delta' mid-heading → expected unrec_found=1" "got=[$_out]"

# T11b: negation guard still holds for the hyphenated form — "not kit-delta" must NOT flip
# unrec_found (mirrors the existing space-form negation guard).
_f="$ROOT/t11b.md"
printf '<!-- review-status: pending -->\n# Retro\n\n## Client-side punch-list (not kit-delta — for the module owner)\n\nprose\n' > "$_f"
_out=$(rgi "$_f")
_rest="${_out#*$'\001'}"; _rest="${_rest#*$'\001'}"; _uf="${_rest%%$'\001'*}"
[ "$_uf" = "0" ] && ok "T11b: negated hyphenated 'not kit-delta' → unrec_found stays 0" "[$_out]" \
  || no "T11b: negated hyphenated 'not kit-delta' → expected unrec_found=0" "got=[$_out]"

# T12: standalone H3 "### Proposals" heading OUTSIDE any canonical section (real fleet form,
# niagara-research retro: "### Proposals (propose-never-apply) — ...") sets unrec_found=1 (Rule 4).
_f="$ROOT/t12.md"
printf '<!-- review-status: pending -->\n# Retro\n\n## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\nprose\n' > "$_f"
_out=$(rgi "$_f")
_rest="${_out#*$'\001'}"; _rest="${_rest#*$'\001'}"; _uf="${_rest%%$'\001'*}"
[ "$_uf" = "1" ] && ok "T12: standalone H3 '### Proposals' outside section → unrec_found=1" "[$_out]" \
  || no "T12: standalone H3 '### Proposals' → expected unrec_found=1" "got=[$_out]"

# T13: list-edge guard — "### Proposals" INSIDE a canonical section must NOT double-fire Rule 4
# (it is legitimately a form-2 candidate there, gated by in_sec, not an unrecognised heading).
_f="$ROOT/t13.md"
{ printf '<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n'
  printf '### Proposals\n\nprose\n'
} > "$_f"
_out=$(rgi "$_f")
_rest="${_out#*$'\001'}"; _rest="${_rest#*$'\001'}"; _uf="${_rest%%$'\001'*}"
[ "$_uf" = "0" ] && ok "T13: '### Proposals' INSIDE canonical section → unrec_found stays 0 (gated by in_sec)" "[$_out]" \
  || no "T13: '### Proposals' inside canonical section → expected unrec_found=0" "got=[$_out]"

# T9: idempotent sourcing — sourcing the lib a second time must not re-define the function
# (the if ! typeset -f guard prevents it). We check by calling the function after double-source.
# shellcheck source=../lib/retro-grammar.sh
. "$RG_LIB"
typeset -f retro_grammar_delta_info >/dev/null 2>&1 \
  && ok "T9: double-source idempotent — function still defined after second source" \
  || no "T9: double-source idempotent — function GONE after second source"

# ── ZSH compatibility: typeset -f guard must work when sourced from zsh (#903) ──
# Probe for zsh: typed skip if absent (never a silent pass).
echo "-- ZSH-GUARD: typeset -f guard defines function when sourced from zsh --"
_zsh_bin="$(type -P zsh 2>/dev/null || true)"
if [ -z "$_zsh_bin" ]; then
  skip "ZSH-GUARD: zsh not found — typed skip (would verify function defined under zsh)"
else
  _zsh_out="$("$_zsh_bin" -c ". '$RG_LIB'; typeset -f retro_grammar_delta_info >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" 2>&1)"
  if [ "$_zsh_out" = "DEFINED" ]; then
    ok "ZSH-GUARD: retro_grammar_delta_info defined after sourcing from zsh (typeset -f portable guard)" "()"
  else
    no "ZSH-GUARD: retro_grammar_delta_info NOT defined after sourcing from zsh" "out=[$_zsh_out]"
  fi
fi

# ── RETRO-TRAP: research-sdd/retros/ must not exist (#903) ──────────────────
# Kit session retros live in top-level retros/ — never in research-sdd/retros/.
# assert_no_rsd_retros_dir <root>: exits 0 if research-sdd/retros/ absent, 1 if present.
assert_no_rsd_retros_dir() {
  local root="$1"
  if [ -d "$root/research-sdd/retros" ]; then
    echo "RETRO-TRAP: research-sdd/retros/ exists under $root; kit retros belong in top-level retros/" >&2
    return 1
  fi
  return 0
}
_repo_root="$(cd "$HERE/../../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
if assert_no_rsd_retros_dir "$_repo_root" 2>/dev/null; then
  ok "RETRO-TRAP: research-sdd/retros/ absent (kit retros in top-level retros/)" "()"
else
  no "RETRO-TRAP: research-sdd/retros/ EXISTS — move retros to top-level retros/" ""
fi

# ── retro_grammar_entry_ids (kit issue #1332 item 2) ───────────────────────────
# The ID of every `### <id> — …` entry heading under the canonical section (sweep-retros form 2).
echo "-- retro_grammar_entry_ids: ### D<N> — entry IDs (form 2) --"
if ! declare -F retro_grammar_entry_ids >/dev/null 2>&1; then
  no "T20 retro_grammar_entry_ids is defined" "function missing after sourcing the lib"
else
  _e="$ROOT/entries.md"
  printf '# r\n\n## Proposed Kit Deltas\n\n### D1 — first\nbody\n\n### Rationale\nnot an entry (no dash)\n\n### D2. — second\n\n### PN-A — third\n\n### (misc) — token is not an ID\n\n## Other\n\n### D9 — outside the section\n' > "$_e"
  _got="$(retro_grammar_entry_ids "$_e" | tr '\n' ',')"
  [ "$_got" = "D1,D2,PN-A," ] \
    && ok "T20 entry IDs: first/middle/last positions, no-dash and out-of-section headings skipped" "($_got)" \
    || no "T20 entry IDs" "got=[$_got] want=[D1,D2,PN-A,]"

  # LIST EDGE: a single entry as the LAST line, no trailing newline.
  printf '## Proposed kit deltas\n\n### D7 — only' > "$ROOT/entries-one.md"
  _got="$(retro_grammar_entry_ids "$ROOT/entries-one.md" | tr '\n' ',')"
  [ "$_got" = "D7," ] && ok "T21 single entry on the last line (no trailing newline)" "($_got)" \
    || no "T21 single last-line entry" "got=[$_got]"

  # Table form: no ### entries -> nothing (the table path owns it).
  mkfix_canonical "$ROOT/entries-table.md" 2
  _got="$(retro_grammar_entry_ids "$ROOT/entries-table.md" | tr '\n' ',')"
  [ -z "$_got" ] && ok "T22 table-form retro yields no entry IDs" "()" \
    || no "T22 table-form retro" "got=[$_got]"

  # Absent input: typed non-zero, never an empty success.
  retro_grammar_entry_ids "$ROOT/does-not-exist.md" >/dev/null 2>&1; _rc=$?
  [ "$_rc" -ne 0 ] && ok "T23 absent file → non-zero (not a silent empty)" "(rc=$_rc)" \
    || no "T23 absent file must fail" "rc=$_rc"

  # Agreement with the shared counter: the number of IDs equals delta_info's form-2 count.
  # (T20's file also carries one heading whose token is not an ID — skipped by design — so the
  # agreement check uses its own file where every entry has a usable ID.)
  printf '## Proposed kit deltas\n\n### D1 — a\n\n### D2 — b\n\n### D3 — c\n' > "$ROOT/entries-clean.md"
  _e="$ROOT/entries-clean.md"
  _cnt="$(rgi_first "$_e")"; _n="$(retro_grammar_entry_ids "$_e" | wc -l | tr -d ' ')"
  [ "$_cnt" = "1:2:3" ] && [ "$_n" = 3 ] && ok "T24 ID count agrees with delta_info form 2 (1:2:3)" "($_cnt vs $_n)" \
    || no "T24 count agreement" "delta_info=[$_cnt] ids=$_n"
fi


# ── retro_grammar_entry_rows / retro_grammar_entry_warn (kit issue #1332 N1, N6) ──
echo "-- retro_grammar_entry_rows: seedable fields per entry; entry_warn: ID gap --"
if ! declare -F retro_grammar_entry_rows >/dev/null 2>&1 || ! declare -F retro_grammar_entry_warn >/dev/null 2>&1; then
  no "T25 retro_grammar_entry_rows / retro_grammar_entry_warn defined" "function missing after sourcing the lib"
else
  _er="$ROOT/entry-rows.md"
  printf '## Proposed kit deltas\n\n### D1 — Pin versions\n**Priority**: MEDIUM — fires often\n**Kit file / section**: METHODOLOGY §5\n**Evidence**: ops-B2\n\n### D2 — second one\n**What**: x\n\n### Rationale\n**Priority**: HIGH\n' > "$_er"
  _rows="$(retro_grammar_entry_rows "$_er")"
  IFS=$'\037' read -r _i _t _g _e _y _p <<<"$(sed -n 1p <<<"$_rows")"
  [ "$_i|$_t|$_g|$_e|$_y|$_p" = "D1|Pin versions|METHODOLOGY §5|ops-B2||MEDIUM" ] \
    && ok "T25 entry row D1: id, title after the dash, target, evidence, empty type, priority first word" "()" \
    || no "T25 entry row D1" "got=[$_i|$_t|$_g|$_e|$_y|$_p]"
  IFS=$'\037' read -r _i _t _g _e _y _p <<<"$(sed -n 2p <<<"$_rows")"
  [ "$_i|$_t|$_p" = "D2|second one|" ] && [ "$(wc -l <<<"$_rows" | tr -d ' ')" = 2 ] \
    && ok "T26 LAST entry has no fields; a later non-entry ### heading's **Priority** does not bleed into it" "()" \
    || no "T26 last entry / bleed" "got=[$_i|$_t|$_p] rows=[$_rows]"
  # ids are exactly the first column of the rows (one parser)
  [ "$(retro_grammar_entry_ids "$_er" | tr '\n' ',')" = "D1,D2," ] \
    && ok "T27 retro_grammar_entry_ids == first column of retro_grammar_entry_rows" "()" \
    || no "T27 ids vs rows" "ids=[$(retro_grammar_entry_ids "$_er" | tr '\n' ',')]"
  # N6 warn: 1 usable id of 2 form-2 entries
  printf '## Proposed kit deltas\n\n### **D1** — bold\n\n### D2 — plain\n' > "$ROOT/entry-gap.md"
  _w="$(retro_grammar_entry_warn "$ROOT/entry-gap.md")"
  [[ "$_w" == WARN:*"1 of 2"* ]] && ok "T28 entry_warn: ID gap → WARN naming 1 of 2" "($_w)" || no "T28 entry_warn gap" "got=[$_w]"
  _w="$(retro_grammar_entry_warn "$_er")"
  [ -z "$_w" ] && ok "T29 entry_warn: no gap → silent" "()" || no "T29 entry_warn clean" "got=[$_w]"
  _w="$(retro_grammar_entry_warn "$ROOT/entries-table.md")"
  [ -z "$_w" ] && ok "T30 entry_warn: table-form retro → silent" "()" || no "T30 entry_warn table" "got=[$_w]"
fi

# ── Fence tracking + heading priority (kit issues #1356 items 1-2, #1369 b) ──
echo "-- fence tracking: a fenced '### D<N> —' / '## Proposed kit deltas' is documentation, not an entry --"
_fe="$ROOT/fence-a.md"
printf '## Proposed kit deltas\n\n### D1 — real one\n**Priority**: LOW\n\n```markdown\n### D99 — fake in fence\n**Priority**: HIGH\n```\n\n### D2 — real two\n' > "$_fe"
_got="$(retro_grammar_entry_ids "$_fe" | tr '\n' ',')"
[ "$_got" = "D1,D2," ] && ok "T31 fenced '### D99 —' is not an entry (ids D1,D2)" "($_got)" || no "T31 fenced entry" "got=[$_got] want=[D1,D2,]"
_got="$(rgi_first "$_fe")"
[ "$_got" = "1:2:2" ] && ok "T31b delta_info counts 2 entries (fenced one not counted)" "($_got)" || no "T31b delta_info fenced count" "got=[$_got] want=[1:2:2]"
printf '## Proposed kit deltas\n\n### D1 — real\n\n```\n### **X** — fenced fake with an unusable ID token\n```\n' > "$ROOT/fence-warn.md"
_w="$(retro_grammar_entry_warn "$ROOT/fence-warn.md")"
[ -z "$_w" ] && ok "T31c a fenced fake entry cannot desync the ID-gap WARN (silent)" "()" || no "T31c entry_warn with fence" "got=[$_w]"
IFS=$'\037' read -r _i _t _g _e _y _p <<<"$(retro_grammar_entry_rows "$_fe" | sed -n 1p)"
[ "$_p" = "LOW" ] && ok "T31d fenced **Priority**: HIGH does not overwrite the real entry's priority" "($_p)" || no "T31d fenced priority bleed" "got=[$_p]"

# tilde fence holding a backtick line; a shorter closer and a closer carrying text do NOT close
printf '## Proposed kit deltas\n\n### D1 — a\n\n~~~~\n```\n### D50 — fake\n~~~\n### D51 — still fenced (short closer)\n~~~~ tail\n### D52 — still fenced (closer with text)\n~~~~\n\n### D2 — b\n' > "$ROOT/fence-b.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-b.md" | tr '\n' ',')"
[ "$_got" = "D1,D2," ] && ok "T32 CommonMark closer rules: same char, >= opener length, nothing after it" "($_got)" || no "T32 closer rules" "got=[$_got] want=[D1,D2,]"

# CRLF file: the closer ends in \r and must still close
printf '## Proposed kit deltas\r\n\r\n### D1 — a\r\n\r\n```\r\n### D9 — fake\r\n```\r\n\r\n### D2 — b\r\n' > "$ROOT/fence-crlf.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-crlf.md" | tr '\n' ',')"
[ "$_got" = "D1,D2," ] && ok "T33 CRLF closer still closes the fence (entries after it are seen)" "($_got)" || no "T33 CRLF closer" "got=[$_got] want=[D1,D2,]"

# indented opener: 4+ spaces is indented code, NOT a fence (#1369 b); up to 3 spaces IS a fence
printf '## Proposed kit deltas\n\n### D1 — a\n\n    ```\n### D2 — after indented code\n### D3 — c\n' > "$ROOT/fence-ind4.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-ind4.md" | tr '\n' ',')"
[ "$_got" = "D1,D2,D3," ] && ok "T34 a 4-space-indented fence opener opens nothing (D2, D3 stay visible)" "($_got)" || no "T34 indented opener" "got=[$_got] want=[D1,D2,D3,]"
printf '## Proposed kit deltas\n\n### D1 — a\n\n   ```\n### D8 — fake\n   ```\n### D2 — b\n' > "$ROOT/fence-ind3.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-ind3.md" | tr '\n' ',')"
[ "$_got" = "D1,D2," ] && ok "T34b a 3-space-indented fence IS a fence" "($_got)" || no "T34b 3-space fence" "got=[$_got] want=[D1,D2,]"
printf '## Proposed kit deltas\n\n### D1 — a\n\n```\n### D8 — fake\n    ```\n### D2 — hidden: an indented line cannot close\n```\n### D3 — c\n' > "$ROOT/fence-ind4c.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-ind4c.md" | tr '\n' ',')"
[ "$_got" = "D1,D3," ] && ok "T34c a 4-space-indented closer does not close the fence" "($_got)" || no "T34c indented closer" "got=[$_got] want=[D1,D3,]"

# 4-space-indented fence lines in PAIR: indented code on both sides, so nothing between them is fenced
printf '## Proposed kit deltas\n\n### D1 — a\n\n    ```\n### D2 — between two indented lines\n    ```\n### D3 — c\n' > "$ROOT/fence-ind4pair.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-ind4pair.md" | tr '\n' ',')"
[ "$_got" = "D1,D2,D3," ] && ok "T34d two 4-space-indented fence lines do not fence what lies between them" "($_got)" || no "T34d indented pair" "got=[$_got] want=[D1,D2,D3,]"

# a backtick opener whose info string holds a backtick is inline code, not a fence
printf '## Proposed kit deltas\n\n### D1 — a\n\n```a`b\n### D2 — after inline code\n```\n### D3 — c\n' > "$ROOT/fence-btick.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-btick.md" | tr '\n' ',')"
[ "$_got" = "D1,D2,D3," ] && ok "T38 a backtick opener with a backtick in its info string is not a fence" "($_got)" || no "T38 info-string backtick" "got=[$_got] want=[D1,D2,D3,]"

# an unclosed fence fails OPEN: nothing is silently swallowed to EOF
printf '## Proposed kit deltas\n\n### D1 — a\n\n```\n### D2 — after an unclosed opener\n' > "$ROOT/fence-open.md"
_got="$(retro_grammar_entry_ids "$ROOT/fence-open.md" | tr '\n' ',')"
[ "$_got" = "D1,D2," ] && ok "T35 an unclosed fence is not a fence: entries after it are still counted (no silent zero)" "($_got)" || no "T35 unclosed fence" "got=[$_got] want=[D1,D2,]"

# a fenced canonical heading opens no section (fence on line 1, closer is the last line, no trailing newline)
printf '```\n## Proposed kit deltas\n\n### D1 — fake\n```' > "$ROOT/fence-head.md"
_got="$(rgi_first "$ROOT/fence-head.md")"
[ "$_got" = "0:n:0" ] && ok "T36 a fenced canonical heading opens no section (first/last-line fence edges)" "($_got)" || no "T36 fenced heading" "got=[$_got] want=[0:n:0]"

echo "-- heading-only priority: '(priority: high)' / '(NEW, MEDIUM)' --"
_hp="$ROOT/headprio.md"
printf '## Proposed kit deltas\n\n### D1 — Title one (priority: high)\n\n### D2 — Title two (NEW, MEDIUM)\n\n### D3 — fix it (low-risk change)\n\n### D4 — keep (medium confidence)\n\n### D5 — body wins (priority: low)\n**Priority**: HIGH\n\n### D6 — last (LOW)\n' > "$_hp"
_got="$(retro_grammar_entry_rows "$_hp" | awk -F'\037' '{printf "%s=%s,", $1, $6}')"
[ "$_got" = "D1=high,D2=MEDIUM,D3=,D4=,D5=HIGH,D6=LOW," ] \
  && ok "T37 heading priority read; look-alikes ignored; body **Priority** wins; first/last edges" "($_got)" \
  || no "T37 heading priority" "got=[$_got] want=[D1=high,D2=MEDIUM,D3=,D4=,D5=HIGH,D6=LOW,]"

echo ""
echo "== $pass passed · $fail failed =="
echo ""

# ── TEETH (--prove-teeth): both-consumers-flip + guard mutations ─────────────
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
# kit issue #1108: sweep-retros.sh now sources lib/hook-wiring.sh for its WIRING-STATUS pass.
cp "$HERE/../lib/hook-wiring.sh" "$_kit/toolbelt/lib/hook-wiring.sh"

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

# ── kit issue #1129 finding 3 / Q5: direct lib-level mutation controls for each new grammar
# rule (T10 Spanish alias, T11 Rule 2 hyphen widening, T12 Rule 4 standalone-Proposals). Each
# mutates a throwaway copy of lib/retro-grammar.sh and re-runs retro_grammar_delta_info against
# it in a fresh subshell — never the live lib. ─────────────────────────────────────────────────

# Tooth SPANISH1: remove the Spanish canonical alias line. T10's fixture must revert to 0:n:0.
echo "-- teeth SPANISH1: remove the Spanish canonical alias; T10 must revert to 0:n:0 --"
_rg_content="$(cat "$RG_LIB")"
_anchor_sp1='  if (low ~ /^## propuesta de deltas al kit([[:space:]]|$)/) return 1'
if [[ "$_rg_content" == *"$_anchor_sp1"* ]]; then
  _mut_sp1="$ROOT/rg-sp1.sh"
  printf '%s\n' "${_rg_content/"$_anchor_sp1"/}" > "$_mut_sp1"
  "$BASH_BIN" -n "$_mut_sp1" 2>/dev/null || no "teeth SPANISH1: mutant syntax check" "bash -n failed"
  _f_sp1="$ROOT/rg-sp1-fixture.md"
  { printf '<!-- review-status: pending -->\n# Retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
    printf '| # | change | target | evidence | type | prio |\n|---|---|---|---|---|---|\n| 1 | ch1 | f.md | B001 | new | H |\n'
  } > "$_f_sp1"
  _out_sp1="$("$BASH_BIN" -c '. "$1"; retro_grammar_delta_info "$2"' _ "$_mut_sp1" "$_f_sp1" 2>&1)"
  _ffc_sp1="${_out_sp1%%$'\001'*}"
  [ "$_ffc_sp1" = "0:n:0" ] \
    && ok "teeth SPANISH1: Spanish alias removed → T10 reverts to 0:n:0 (has teeth)" "()" \
    || no "teeth SPANISH1: Spanish alias removed → should revert to 0:n:0" "got=[$_out_sp1]"
else
  no "teeth SPANISH1: locate the Spanish canonical alias" "anchor not found — lib drifted?"
fi

# Tooth RULE2-1: revert Rule 2's hyphen widening. T11's fixture must revert to unrec_found=0.
echo "-- teeth RULE2-1: revert Rule 2's hyphen widening; T11 must revert to unrec_found=0 --"
_anchor_r2='if (!is_unrec && low ~ /[ -]kit[ -]delt/ && low !~ /not[ -]+kit[ -]+delt/) is_unrec=1'
if [[ "$_rg_content" == *"$_anchor_r2"* ]]; then
  _mut_r2="$ROOT/rg-r2.sh"
  _reverted_r2='if (!is_unrec && low ~ / kit delt/ && low !~ /not +kit +delt/) is_unrec=1'
  printf '%s\n' "${_rg_content/"$_anchor_r2"/"$_reverted_r2"}" > "$_mut_r2"
  "$BASH_BIN" -n "$_mut_r2" 2>/dev/null || no "teeth RULE2-1: mutant syntax check" "bash -n failed"
  _f_r2="$ROOT/rg-r2-fixture.md"
  printf '<!-- review-status: pending -->\n# Retro\n\n## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nprose\n' > "$_f_r2"
  _out_r2="$("$BASH_BIN" -c '. "$1"; retro_grammar_delta_info "$2"' _ "$_mut_r2" "$_f_r2" 2>&1)"
  _rest_r2="${_out_r2#*$'\001'}"; _rest_r2="${_rest_r2#*$'\001'}"; _uf_r2="${_rest_r2%%$'\001'*}"
  [ "$_uf_r2" = "0" ] \
    && ok "teeth RULE2-1: Rule 2 hyphen widening reverted → T11 reverts to unrec_found=0 (has teeth)" "()" \
    || no "teeth RULE2-1: Rule 2 hyphen widening reverted → should revert to unrec_found=0" "got=[$_out_r2]"
else
  no "teeth RULE2-1: locate Rule 2's hyphen-widened pattern" "anchor not found — lib drifted?"
fi

# Tooth RULE4-1: disable Rule 4 (standalone H3 Proposals outside section). T12's fixture must
# revert to unrec_found=0.
echo "-- teeth RULE4-1: disable Rule 4; T12 must revert to unrec_found=0 --"
_anchor_r4='      !in_sec && /^###[^#]/ {
        if (!unrec_found && low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) {
          unrec_found=1; unrec_heading=$0
        }
        next
      }'
if [[ "$_rg_content" == *"$_anchor_r4"* ]]; then
  _mut_r4="$ROOT/rg-r4.sh"
  printf '%s\n' "${_rg_content/"$_anchor_r4"/}" > "$_mut_r4"
  "$BASH_BIN" -n "$_mut_r4" 2>/dev/null || no "teeth RULE4-1: mutant syntax check" "bash -n failed"
  _f_r4="$ROOT/rg-r4-fixture.md"
  printf '<!-- review-status: pending -->\n# Retro\n\n## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\nprose\n' > "$_f_r4"
  _out_r4="$("$BASH_BIN" -c '. "$1"; retro_grammar_delta_info "$2"' _ "$_mut_r4" "$_f_r4" 2>&1)"
  _rest_r4="${_out_r4#*$'\001'}"; _rest_r4="${_rest_r4#*$'\001'}"; _uf_r4="${_rest_r4%%$'\001'*}"
  [ "$_uf_r4" = "0" ] \
    && ok "teeth RULE4-1: Rule 4 disabled → T12 reverts to unrec_found=0 (has teeth)" "()" \
    || no "teeth RULE4-1: Rule 4 disabled → should revert to unrec_found=0" "got=[$_out_r4]"
else
  no "teeth RULE4-1: locate Rule 4 (standalone H3 Proposals)" "anchor not found — lib drifted?"
fi

# ── ZSH-GUARD teeth: declare-F mutant leaves function undefined under zsh ────
echo "-- ZSH-GUARD teeth: declare-F mutant must fail to define function under zsh --"
if [ -z "${_zsh_bin:-}" ]; then
  skip "ZSH-GUARD teeth: zsh not found — typed skip (would verify declare-F mutant leaves function undefined)"
else
  _rg_mut="$ROOT/rg-zsh-mut-$$.sh"
  sed 's/^if ! typeset -f retro_grammar_delta_info/if ! declare -F retro_grammar_delta_info/' "$RG_LIB" > "$_rg_mut"
  _zsh_mut_out="$("$_zsh_bin" -c ". '$_rg_mut'; typeset -f retro_grammar_delta_info >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" 2>&1)"
  if [ "$_zsh_mut_out" = "UNDEFINED" ]; then
    ok "ZSH-GUARD teeth: declare-F mutant leaves function undefined under zsh (mutation has teeth)" "()"
  else
    no "ZSH-GUARD teeth: declare-F mutant should leave function undefined under zsh — tooth broken" "out=[$_zsh_mut_out]"
  fi
  rm -f "$_rg_mut"
fi

# ── SKIP-FORMAT teeth: skip() in the real suite must output SKIP, not PASS ──────
# Phase 1: assert the real file itself outputs '  SKIP  ' under hermetic no-zsh PATH
#          (proves skip() is correct before we test its mutation).  A broken skip()
#          that already prints PASS would fail this check immediately.
# Phase 2: copy the real file into a mirror tree so HERE/../lib/ resolves to the real lib
#          (Blocker 2: a copy at $ROOT would try $ROOT/../lib/ → FATAL exit 2 before output).
#          Mutate skip() to print PASS, assert the mutant exits 0 with a summary line
#          (proves it ran, not just crashed), then assert SKIP is gone.
# Precondition for both phases: zsh must be unreachable under the hermetic PATH.
echo "-- SKIP-FORMAT teeth: real skip() must output SKIP; mutant must not --"
# Build hermetic no-zsh PATH by removing the directory that contains zsh.
# This is reliable when bash and zsh are in different directories.
# When they share a directory (e.g. /usr/bin on some systems), bash would also
# disappear from PATH and the child prints "FATAL: bash not on PATH" — in that case
# we issue a typed-SKIP rather than a false FAIL (Blocker 3 fix).
_sf_zsh="$(type -P zsh 2>/dev/null || true)"
if [ -n "$_sf_zsh" ]; then
  _sf_zsh_dir="$(dirname "$_sf_zsh")"
  _sf_nozsh="$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -Fxv "$_sf_zsh_dir" | tr '\n' ':' | sed 's/:$//')"
else
  _sf_nozsh="$PATH"
fi
# Verify precondition: zsh must be unreachable under the hermetic PATH
_sf_zsh_check="$("$BASH_BIN" -c "PATH='$_sf_nozsh' type -P zsh 2>/dev/null || true")"
# Also verify bash and core tools remain accessible (guard against shared-dir systems)
_sf_bash_check="$("$BASH_BIN" -c "PATH='$_sf_nozsh' type -P bash 2>/dev/null || true")"
# Recursion guard: the children below re-run this file WITHOUT --prove-teeth (so they exit
# before this block), and RG_SKIPFMT_CHILD makes that bound explicit if that ever changes.
if [ -n "${RG_SKIPFMT_CHILD:-}" ]; then
  skip "SKIP-FORMAT teeth: nested invocation — not re-entered"
elif [ -n "$_sf_zsh_check" ]; then
  skip "SKIP-FORMAT teeth: zsh still reachable under hermetic PATH ($_sf_zsh_check) — typed skip"
elif [ -z "$_sf_bash_check" ]; then
  skip "SKIP-FORMAT teeth: bash not in hermetic PATH (bash and zsh share a directory) — typed skip"
else
  # Phase 1: real file must produce a SKIP line (proves skip() outputs SKIP)
  _sf_real_out="$(RG_SKIPFMT_CHILD=1 PATH="$_sf_nozsh" "$BASH_BIN" "$0" 2>&1)"
  if ! grep -q '  SKIP  ' <<<"$_sf_real_out"; then
    no "SKIP-FORMAT teeth: real skip() must output '  SKIP  ' under no-zsh — format is wrong" "out=[$_sf_real_out]"
  else
    # Build mirror tree so copies resolve HERE/../lib/ → real lib — Blocker 2 fix.
    _sf_mirror="$ROOT/sf-mirror"
    mkdir -p "$_sf_mirror/tests"
    ln -s "$HERE/../lib"             "$_sf_mirror/lib"
    ln -s "$HERE/../sweep-retros.sh" "$_sf_mirror/sweep-retros.sh"
    ln -s "$HERE/../verify-retro.sh" "$_sf_mirror/verify-retro.sh"
    # Sabotage check: unmutated copy in mirror tree must still show SKIP.
    # Proves the mirror tree setup is sound — only the mutation changes behavior.
    _sf_sab="$_sf_mirror/tests/retro-grammar-sab.sh"
    cp "$0" "$_sf_sab"
    _sf_sab_out="$(RG_SKIPFMT_CHILD=1 PATH="$_sf_nozsh" "$BASH_BIN" "$_sf_sab" 2>&1)"
    if ! grep -q '  SKIP  ' <<<"$_sf_sab_out"; then
      no "SKIP-FORMAT teeth: sabotage — unmutated mirror copy must output SKIP" "out=[$_sf_sab_out]"
    else
      ok "SKIP-FORMAT teeth: sabotage — unmutated mirror copy shows SKIP (mirror tree sound)" "(SKIP present)"
      # Phase 2: mutate the copy (SKIP→PASS in skip() body) and assert SKIP disappears
      _sf_copy="$_sf_mirror/tests/retro-grammar-tooth.sh"
      sed '/^skip() /s/  SKIP  /  PASS  /' "$0" > "$_sf_copy"
      _sf_out="$(RG_SKIPFMT_CHILD=1 PATH="$_sf_nozsh" "$BASH_BIN" "$_sf_copy" 2>&1)"
      _sf_rc=$?
      # Assert mutant ran (exits 0 with passed summary) — if it exits 2 the tooth is theater
      if [ "$_sf_rc" -ne 0 ] || ! grep -qE '== [0-9]+ passed' <<<"$_sf_out"; then
        no "SKIP-FORMAT teeth: mutant must exit 0 with passed summary — harness error" "rc=$_sf_rc out=[$_sf_out]"
      elif ! grep -q '  SKIP  ' <<<"$_sf_out"; then
        ok "SKIP-FORMAT teeth: real skip()→PASS mutant has no SKIP line — format mutation detected" "(SKIP absent)"
      else
        no "SKIP-FORMAT teeth: mutant still outputs SKIP — skip() tooth not working" "out=[$_sf_out]"
      fi
    fi
  fi
fi

# ── RETRO-TRAP teeth: trap dir fixture must fire the guard ───────────────────
echo "-- RETRO-TRAP teeth: guard must reject research-sdd/retros/ fixture --"
_trap_root="$ROOT/trap-root"
mkdir -p "$_trap_root/research-sdd/retros"
_trap_err="$(assert_no_rsd_retros_dir "$_trap_root" 2>&1)"
_trap_rc=$?
if [ "$_trap_rc" != 0 ] && grep -q "RETRO-TRAP" <<<"$_trap_err"; then
  ok "RETRO-TRAP teeth: present research-sdd/retros/ → guard exits 1 + message (mutation has teeth)" "()"
else
  no "RETRO-TRAP teeth: guard should reject trap dir" "rc=$_trap_rc err=[$_trap_err]"
fi

# ── retro_grammar_entry_ids teeth (kit issue #1332 item 2) — mutants via tests/lib/mutant.sh ────
echo "-- teeth T1332-L: retro_grammar_entry_ids mutants (T20-T24 must flip) --"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
_el_e="$ROOT/el-entries.md"
printf '# r\n\n## Proposed Kit Deltas\n\n### D1 — first\n\n### Rationale\n\n### D2. — second\n\n### PN-A — third\n\n### (misc) — token is not an ID\n\n## Other\n\n### D9 — outside the section\n' > "$_el_e"
# el_mutant <tag> <sed-expr>: the mutant must change the ID list produced for T20's file
el_mutant() {
  local tag="$1" expr="$2" mlib="$ROOT/el-mut-$1.sh" got
  if ! mutant_sed "$RG_LIB" "$mlib" -e "$expr"; then no "T1332-L$tag: build mutant" "mutant_sed refused"; return; fi
  got="$("$BASH_BIN" -c '. "$1"; retro_grammar_entry_ids "$2"' _ "$mlib" "$_el_e" 2>/dev/null | tr '\n' ',')"
  if [ "$got" != "D1,D2,PN-A," ]; then ok "T1332-L$tag teeth: mutant changes the ID list → T20 has teeth" "(got $got)"
  else no "T1332-L$tag teeth: mutant must change the ID list" "T20 is THEATER: got=[$got]"; fi
}
el_mutant 1 's/^      \/\^##\[^#\]\/                 { flush(); in_sec=0; next }$/      \/^##[^#]\/ { flush(); next }/'
el_mutant 2 's/sub(\/\[.:\]+\$\/, "", id)/id=id/'
el_mutant 3 's/if (id ~ \/\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\*\$\/) { have=1;/if (1) { have=1;/'
el_mutant 4 's/^      is_canonical_heading(low) { flush(); in_sec=1; next }$/      is_canonical_heading(low) { next }/'

# lib_mutant <tag> <sed-expr> <good-output> <function> <file>: the mutant lib must change what the
# function prints for the file (cases T25-T30 compare exactly that output). mutant_sed refuses a
# vacuous / identical / broken mutant, so a refusal is a FAIL.
lib_mutant() {
  local tag="$1" expr="$2" good="$3" fn="$4" file="$5" mlib="$ROOT/lm-$1.sh" got
  if ! mutant_sed "$RG_LIB" "$mlib" -e "$expr"; then no "T1332-$tag: build mutant" "mutant_sed refused"; return; fi
  got="$("$BASH_BIN" -c '. "$1"; "$2" "$3"' _ "$mlib" "$fn" "$file" 2>/dev/null | tr '\n\037' ',|')"
  if [ "$got" != "$good" ]; then ok "T1332-$tag teeth: mutant changes $fn output → cases have teeth" "(got $got)"
  else no "T1332-$tag teeth: mutant must change $fn output" "THEATER: got=[$got]"; fi
}
_er_good="D1|Pin versions|METHODOLOGY §5|ops-B2||MEDIUM,D2|second one||||,"
lib_mutant R1 's/title=substr(t, d + length("—"));/title=t;/' "$_er_good" retro_grammar_entry_rows "$ROOT/entry-rows.md"
lib_mutant R2 's/^        flush()$/        have=have/' "$_er_good" retro_grammar_entry_rows "$ROOT/entry-rows.md"
lib_mutant R3 's/pr=pw\[1\]; gsub(\/\[^A-Za-z\]\/, "", pr)/pr=rest/' "$_er_good" retro_grammar_entry_rows "$ROOT/entry-rows.md"
_warn_good="WARN: entry-gap.md: only 1 of 2 '### … —' entries have a usable ID token (a '**D1**' or '[D1]' token is not trackable) — count by hand,"
lib_mutant W1 's/\[ "\$n" -lt "\$cnt" \]/[ "$n" -lt 0 ]/' "$_warn_good" retro_grammar_entry_warn "$ROOT/entry-gap.md"
lib_mutant W2 's/\[ "\$form" = "2" \] || return 0/:/' "" retro_grammar_entry_warn "$ROOT/entries-table.md"

# ── mutation controls for fence tracking + heading priority (kit issues #1356 items 1-2, #1369 b) ──
# fence_mutant <tag> <sed-expr> <fixture> <function>: the mutant lib must change what the function prints
# for the fixture, and the unmutated lib must print <want> (so the control cannot pass vacuously).
fence_mutant() {
  local tag="$1" expr="$2" file="$3" fn="$4" want="$5" mlib="$ROOT/fm-$1.sh" good got
  good="$("$BASH_BIN" -c '. "$1"; "$2" "$3"' _ "$RG_LIB" "$fn" "$file" 2>/dev/null | tr '\n\037\001' ',||')"
  [ "$good" = "$want" ] || { no "T1369-$tag: unmutated lib baseline" "got=[$good] want=[$want]"; return; }
  if ! mutant_sed "$RG_LIB" "$mlib" -e "$expr"; then no "T1369-$tag: build mutant" "mutant_sed refused"; return; fi
  got="$("$BASH_BIN" -c '. "$1"; "$2" "$3"' _ "$mlib" "$fn" "$file" 2>/dev/null | tr '\n\037\001' ',||')"
  if [ "$got" != "$good" ]; then ok "T1369-$tag teeth: mutant changes $fn output → cases have teeth" "(got $got)"
  else no "T1369-$tag teeth: mutant must change $fn output" "THEATER: got=[$got]"; fi
}
fence_mutant F1 's/for (k = ostart; k <= FNR; k++) skip\[k\] = 1/k = 0/' "$ROOT/fence-a.md" retro_grammar_entry_ids "D1,D2,"
fence_mutant F2 's/rest ~ \/\^\[ \\t\\r\]\*\$\/) {   # RETRO_GRAMMAR_FENCE_CLOSER/rest ~ \/^[ \\t]*$\/) {   # RETRO_GRAMMAR_FENCE_CLOSER/' "$ROOT/fence-crlf.md" retro_grammar_entry_ids "D1,D2,"
fence_mutant F3 's/if (indent(\$0) >= 4) next /if (0) next /' "$ROOT/fence-ind4pair.md" retro_grammar_entry_ids "D1,D2,D3,"
fence_mutant F3c 's/if (indent(\$0) >= 4) next /if (0) next /' "$ROOT/fence-ind4c.md" retro_grammar_entry_ids "D1,D3,"
fence_mutant F4 's/if (n >= flen \&\& rest/if (n >= 3 \&\& rest/' "$ROOT/fence-b.md" retro_grammar_entry_ids "D1,D2,"
fence_mutant F5 's/ \&\& !(c == "`" \&\& index(rest, "`") > 0)//' "$ROOT/fence-btick.md" retro_grammar_entry_ids "D1,D2,D3,"
fence_mutant F6 's/^      !(FNR in skip) { print }/      !(FNR in skip) \&\& !(open \&\& FNR >= ostart) { print }/' "$ROOT/fence-open.md" retro_grammar_entry_ids "D1,D2,"
fence_mutant D1 '/return 0; }$/{n;s/retro_grammar_defenced "\$f" | awk/cat "$f" | awk/}' "$ROOT/fence-a.md" retro_grammar_delta_info "1:2:2||0|0|,"
fence_mutant E1 '/^    \[ -n "\$f" \] \&\& \[ -f "\$f" \] \&\& \[ -r "\$f" \] || return 1$/{n;s/retro_grammar_defenced "\$f" | awk/cat "$f" | awk/}' "$ROOT/fence-a.md" retro_grammar_entry_ids "D1,D2,"
_hp_good="D1=high,D2=MEDIUM,D3=,D4=,D5=HIGH,D6=LOW,"
hp_mutant() {   # hp_mutant <tag> <sed-expr>: the mutant lib must change T37's priority column
  local tag="$1" expr="$2" mlib="$ROOT/hp-$1.sh" got
  if ! mutant_sed "$RG_LIB" "$mlib" -e "$expr"; then no "T1356-$tag: build mutant" "mutant_sed refused"; return; fi
  got="$("$BASH_BIN" -c '. "$1"; retro_grammar_entry_rows "$2"' _ "$mlib" "$ROOT/headprio.md" 2>/dev/null | awk -F'\037' '{printf "%s=%s,", $1, $6}')"
  if [ "$got" != "$_hp_good" ]; then ok "T1356-$tag teeth: mutant changes the heading-priority column → T37 has teeth" "(got $got)"
  else no "T1356-$tag teeth: mutant must change T37" "THEATER: got=[$got]"; fi
}
hp_mutant H1 's/if (pr == "") pr = hp /pr = pr /'
hp_mutant H2 's/if (pr == "") pr = hp /if (hp != "") pr = hp /'
hp_mutant H3 's/else if (lt != "new" \&\& lt != "priority") ok = 0/else if (0) ok = 0/'
hp_mutant H4 's/lt == "medium" || lt == "low") { if (lvl == "") lvl = tok }/lt == "low") { if (lvl == "") lvl = tok }/'

echo ""
echo "== $pass passed · $fail failed =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
