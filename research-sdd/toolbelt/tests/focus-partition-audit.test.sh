#!/usr/bin/env bash
# focus-partition-audit.test.sh — RED-FIRST harness for focus-partition-audit.sh.
#
# Round 2 (kit issue #1123 / PR #1127 review): the charter source moved from FOCUSES.md's own
# prose to FOCUSES.md classified rows PLUS the RESEARCH-STATE files they name — the real
# niagara-research corpus charters modules there, never in FOCUSES.md itself. New forms:
# RESEARCH-STATE resolution, whitespace-split multi-identifier spans, `<module>-rt/wb/ux/se`
# profile-suffix mapping, glob tokens (`clHVAC*`) matched with shell glob semantics. Fixes:
# absent-FOCUSES.md no longer also prints a generic "no-match" line (F4, two states in one run),
# a prose line merely containing '|' is not a table row (F6), --depth/--top reject non-integers
# (F7), the full dependency probe covers wc/tr/mktemp/basename/head/rm (F5), mktemp/find
# operational failures degrade instead of reading as a confident empty run, and an existing-but-
# unreadable FOCUSES.md is its own typed state.
#
# Teeth (--prove-teeth): (a) hardcoded UNCHARTERED=0 (anchored — must not also clobber
# FAMILIES_UNCHARTERED=), (b) drop backtick-only restriction, (c) split on '.' too (reproduces the
# real Clock.schedule defect), (d) exact-token loosened to substring, (e) family min-length-3 gate
# removed, (f) unclassifiable-row gate loosened, (g) row-shape gate loosened back to bare
# index($0,"|") (F6), (h) dependency probe removed, (i) RESEARCH-STATE resolution disabled (F1 —
# the headline regression), (j) whitespace-split stage removed, (k) profile-suffix expansion
# disabled, (l) glob matching disabled, (m) --depth integer validation removed (F7).
#
# Usage: focus-partition-audit.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../focus-partition-audit.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

run() { bash "$SUT" "$@" 2>/dev/null; }
rune() { bash "$SUT" "$@" 2>&1; }  # include stderr

echo "== focus-partition-audit.test.sh =="

# ---------- helpers: build fixture trees
mk_unit() {
  # mk_unit <subject> <unit-name> [file1 file2 ...]
  local subj="$1" unit="$2"; shift 2
  mkdir -p "$subj/$unit"
  for f; do touch "$subj/$unit/$f"; done
}
mk_focuses() {
  # mk_focuses <corpus-dir> <body-lines...>  (writes FOCUSES.md with a standard header+sep)
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    printf '| Focus | Estado | RESEARCH-STATE | Ambito |\n'
    printf '|---|---|---|---|\n'
    for line; do printf '%s\n' "$line"; done
  } > "$dir/FOCUSES.md"
}
mk_state() {
  # mk_state <corpus-dir> <state-filename> <body-lines...>
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir"
  : > "$dir/$name"
  for line; do printf '%s\n' "$line" >> "$dir/$name"; done
}

# ---- 1. absent subject -> exit 1 + absent-input message
out="$(rune "$ROOT/corpus" --subject "$ROOT/absent_subject" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'absent-input'; then
  ok "absent subject: exit 1 + absent-input message"
else
  no "absent subject: expected exit 1 + absent-input" "rc=$rc out=$out"
fi

# ---- 2. subject exists but has no class-file units -> empty-input, zeroed lines
S2="$ROOT/s2"
mk_unit "$S2" "mod_alpha" "README.txt"
out="$(run "$ROOT/corpus" --subject "$S2")"
if printf '%s' "$out" | grep -q 'subject: empty-input' \
   && printf '%s' "$out" | grep -qE 'units: 0/0 chartered'; then
  ok "empty subject (no .java): empty-input + zeroed units line"
else
  no "empty subject: expected empty-input" "out=$out"
fi

# ---- 3. FOCUSES.md absent (default path) -> focuses:absent-input, everything unchartered,
#         and NEVER also the generic "no-match (...)" line (F4 — two states in one run)
S3="$ROOT/s3"; C3="$ROOT/c3"
mk_unit "$S3" "mod_a" "Alpha.java"
mkdir -p "$C3"   # corpus-dir exists but no FOCUSES.md
out="$(run "$C3" --subject "$S3")"
if printf '%s' "$out" | grep -q 'focuses: absent-input' \
   && printf '%s' "$out" | grep -qE 'units: 0/1 chartered' \
   && ! printf '%s' "$out" | grep -q 'no-match ('; then
  ok "FOCUSES.md absent: absent-input + unchartered, no duplicate no-match line (F4)"
else
  no "FOCUSES.md absent: expected single typed state" "out=$out"
fi

# ---- 4. FOCUSES.md present but zero table rows -> focuses:empty-input
S4="$ROOT/s4"; C4="$ROOT/c4"
mk_unit "$S4" "mod_a" "Alpha.java"
mkdir -p "$C4"; printf 'no table here, just prose\n' > "$C4/FOCUSES.md"
out="$(run "$C4" --subject "$S4")"
if printf '%s' "$out" | grep -q 'focuses: empty-input'; then
  ok "FOCUSES.md present, 0 rows: empty-input state"
else
  no "FOCUSES.md 0 rows: expected empty-input" "out=$out"
fi

# ---- 5. FOCUSES.md has rows but 0 backtick tokens -> focuses:no-match
S5="$ROOT/s5"; C5="$ROOT/c5"
mk_unit "$S5" "mod_a" "Alpha.java"
mk_focuses "$C5" '| module-mechanics | active | | plain prose scope, no code spans |'
out="$(run "$C5" --subject "$S5")"
if printf '%s' "$out" | grep -q 'focuses: no-match' \
   && printf '%s' "$out" | grep -q 'FOCUSES.md rows: 1 classified, 0 unclassifiable'; then
  ok "FOCUSES.md rows present, 0 chartering tokens: no-match + 1 classified row"
else
  no "FOCUSES.md no-match" "out=$out"
fi

# ---- 6. unclassifiable row: blank identity cell is counted, not silently classified
S6="$ROOT/s6"; C6="$ROOT/c6"
mk_unit "$S6" "mod_a" "Alpha.java"
mk_focuses "$C6" \
  '|  | active | | ambito con `mod_a` pero sin identidad de focus |' \
  '| real-focus | active | | scope mentions `mod_a` too |'
out="$(run "$C6" --subject "$S6")"
if printf '%s' "$out" | grep -q 'FOCUSES.md rows: 1 classified, 1 unclassifiable'; then
  ok "unclassifiable row: blank-identity row counted separately, not merged into classified"
else
  no "unclassifiable row: expected 1 classified, 1 unclassifiable" "out=$out"
fi

# ---- 7. backtick-exact charter (from FOCUSES.md's own cell, no RESEARCH-STATE needed)
S7="$ROOT/s7"; C7="$ROOT/c7"
mk_unit "$S7" "mod_a" "Alpha.java"
mk_unit "$S7" "mod_b" "Beta.java"
mk_focuses "$C7" '| some-focus | active | | scope covers `mod_a` mechanics |'
out="$(run "$C7" --subject "$S7")"
if printf '%s' "$out" | grep -qE 'units: 1/2 chartered'; then
  ok "backtick-exact charter: mod_a chartered, mod_b unchartered"
else
  no "backtick-exact charter: expected 1/2 chartered" "out=$out"
fi

# ---- 8. '/'-split path-token charter: `organized/mod_a/Foo.java` charters mod_a
S8="$ROOT/s8"; C8="$ROOT/c8"
mk_unit "$S8" "mod_a" "Alpha.java"
mk_focuses "$C8" '| some-focus | active | | evidence path `organized/mod_a/Foo.java` |'
out="$(run "$C8" --subject "$S8")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "path-token charter: organized/mod_a/... in a backtick span charters mod_a"
else
  no "path-token charter: expected 1/1 chartered" "out=$out"
fi

# ---- 9. false-positive rejection: Clock.schedule (real corpus defect) must not charter "schedule"
S9="$ROOT/s9"; C9="$ROOT/c9"
mk_unit "$S9" "schedule" "BWeeklySchedule.java"
mk_focuses "$C9" '| build-kit-campaign8 | stopped | | the `Clock.schedule` delay/period floor |'
out="$(run "$C9" --subject "$S9")"
if printf '%s' "$out" | grep -qE 'units: 0/1 chartered'; then
  ok "false-positive rejection: Clock.schedule does not falsely charter module 'schedule'"
else
  no "false-positive rejection FAILED: Clock.schedule falsely charters 'schedule'" "out=$out"
fi

# ---- 10. exact-token equality: `modbus` backtick span must not charter unit "modbusCore"
S10="$ROOT/s10"; C10="$ROOT/c10"
mk_unit "$S10" "modbusCore" "BModbusNetwork.java"
mk_focuses "$C10" '| some-focus | active | | see `modbus` driver family |'
out="$(run "$C10" --subject "$S10")"
if printf '%s' "$out" | grep -qE 'units: 0/1 chartered'; then
  ok "exact-token equality: 'modbus' token does not substring-charter 'modbusCore'"
else
  no "exact-token equality FAILED: substring charter leaked through" "out=$out"
fi

# ---- 11. family grouping edges: first/middle/last of a 3-member family + 1 singleton
S11="$ROOT/s11"; C11="$ROOT/c11"
mk_unit "$S11" "lonAaon" "A.java"
mk_unit "$S11" "lonAbb"  "B.java"
mk_unit "$S11" "lonActech" "C.java"
mk_unit "$S11" "ZetaUnit" "D.java"   # starts uppercase -> singleton family (its own name)
mkdir -p "$C11"   # no FOCUSES.md -> everything unchartered
out="$(run "$C11" --subject "$S11")"
if printf '%s' "$out" | grep -qE 'families: 2 total .* 2 fully-unchartered'; then
  ok "family grouping: lon{Aaon,Abb,Actech} cluster into 1 family; ZetaUnit is its own singleton"
else
  no "family grouping edges FAILED" "out=$out"
fi

# ---- 12. --top N ranks unchartered units by file count desc
S12="$ROOT/s12"; C12="$ROOT/c12"
mkdir -p "$S12/big" "$S12/small"
for i in 1 2 3 4 5; do touch "$S12/big/Class${i}.java"; done
touch "$S12/small/OneClass.java"
mkdir -p "$C12"
out="$(run "$C12" --subject "$S12" --top 2)"
first_count="$(printf '%s' "$out" | grep -E '^[0-9]+' | head -1 | awk '{print $1}')"
if [ "${first_count:-0}" -eq 5 ]; then
  ok "--top N: big (5 files) ranks first among unchartered units"
else
  no "--top N: expected first row count=5" "first_count=${first_count:-none} out=$out"
fi

# ---- 13. degraded: a required PATH tool missing -> exit 3 + typed degraded message
TOOLSDIR="$ROOT/mini-path"
mkdir -p "$TOOLSDIR"
for t in bash find grep sed; do
  ln -sf "$(command -v "$t")" "$TOOLSDIR/$t"
done
# deliberately omit awk and sort from the minimal PATH
out="$(PATH="$TOOLSDIR" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'degraded:'; then
  ok "degraded: missing PATH tool -> exit 3 + typed degraded message"
else
  no "degraded state FAILED" "rc=$rc out=$out"
fi

# ---- 14. degraded (F5): `wc` specifically missing must ALSO degrade, not silently 0/0
# (the review's exact reproduction: a narrow probe list let a missing wc through to a false pass)
TOOLSDIR_WC="$ROOT/mini-path-wc"
mkdir -p "$TOOLSDIR_WC"
for t in bash find grep sed awk sort tr mktemp basename head rm; do
  ln -sf "$(command -v "$t")" "$TOOLSDIR_WC/$t"
done
out="$(PATH="$TOOLSDIR_WC" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'degraded: wc not found'; then
  ok "degraded (F5): missing wc -> exit 3, not a silent 0/0 pass"
else
  no "degraded wc FAILED" "rc=$rc out=$out"
fi

# ---- 15. FOCUSES.md exists but unreadable -> its own typed state, never a confident 0/0
S15="$ROOT/s15"; C15="$ROOT/c15"
mk_unit "$S15" "mod_a" "Alpha.java"
mk_focuses "$C15" '| some-focus | active | | scope |'
chmod 000 "$C15/FOCUSES.md"
out="$(run "$C15" --subject "$S15")"
chmod 644 "$C15/FOCUSES.md"  # restore so ROOT cleanup can remove it
if printf '%s' "$out" | grep -q 'focuses: unreadable'; then
  ok "FOCUSES.md unreadable: distinct typed state, not folded into empty-input"
else
  no "FOCUSES.md unreadable FAILED" "out=$out"
fi

# ---- 16. F7: --depth rejects a non-integer with exit 2 (not a silent empty-input)
out="$(rune "$ROOT/corpus" --subject "$ROOT/s2" --depth abc)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'depth must be a non-negative integer'; then
  ok "F7: --depth abc rejected with exit 2"
else
  no "F7: --depth abc should exit 2" "rc=$rc out=$out"
fi

# ---- 17. F7: --top rejects a non-integer with exit 2
out="$(rune "$ROOT/corpus" --subject "$ROOT/s2" --top xyz)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'top must be a non-negative integer'; then
  ok "F7: --top xyz rejected with exit 2"
else
  no "F7: --top xyz should exit 2" "rc=$rc out=$out"
fi

# ---- 18. F6: a prose line merely containing '|' is not a table row
S18="$ROOT/s18"; C18="$ROOT/c18"
mk_unit "$S18" "mod_a" "Alpha.java"
mkdir -p "$C18"
{
  printf '| Focus | Estado | RESEARCH-STATE | Ambito |\n'
  printf '|---|---|---|---|\n'
  printf 'prose line with bit48=ADMIN_READ|ADMIN_WRITE embedded, not a table row\n'
  printf '| real-focus | active | | scope mentions `mod_a` |\n'
} > "$C18/FOCUSES.md"
out="$(run "$C18" --subject "$S18")"
if printf '%s' "$out" | grep -q 'FOCUSES.md rows: 1 classified, 0 unclassifiable'; then
  ok "F6: prose line with embedded '|' is not counted as a table row"
else
  no "F6 FAILED: prose-with-pipe miscounted as a row" "out=$out"
fi

# ---- 19. F1 (headline): charter source is the RESEARCH-STATE file a row NAMES, not the row's
# own FOCUSES.md text — the real defect: modbusCore is chartered only in RESEARCH-STATE-modbus.md
S19="$ROOT/s19"; C19="$ROOT/c19"
mk_unit "$S19" "modbusCore" "BModbusNetwork.java"
mk_focuses "$C19" '| modbus | active | RESEARCH-STATE-modbus.md | the Modbus driver (no module names here) |'
mk_state "$C19" "RESEARCH-STATE-modbus.md" \
  '| item | note | ref | verdict |' \
  '|---|---|---|---|' \
  '| M1 | arch | `modbusCore-rt` root | COVERED -> B294 |'
out="$(run "$C19" --subject "$S19")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "F1: charter resolved from the named RESEARCH-STATE file, not FOCUSES.md's own prose"
else
  no "F1 FAILED: RESEARCH-STATE charter source not read" "out=$out"
fi

# ---- 20. profile-suffix form: `<module>-wb` charters `<module>`
S20="$ROOT/s20"; C20="$ROOT/c20"
mk_unit "$S20" "clCBus" "A.java"
mk_focuses "$C20" '| wb-vendor-ux | active | RESEARCH-STATE-wb-vendor-ux.md | vendor WB survey |'
mk_state "$C20" "RESEARCH-STATE-wb-vendor-ux.md" 'Archetype surveyed: `clCBus-wb` widgets'
out="$(run "$C20" --subject "$S20")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "profile-suffix: clCBus-wb charters module clCBus"
else
  no "profile-suffix FAILED" "out=$out"
fi

# ---- 21. glob token: `clHVAC*` charters matching units, tracked as glob-chartered
S21="$ROOT/s21"; C21="$ROOT/c21"
mk_unit "$S21" "clHVACChiller" "A.java"
mk_unit "$S21" "unrelated" "B.java"
mk_focuses "$C21" '| kitControl | active | | control HVAC libs (`clHVAC*`) |'
out="$(run "$C21" --subject "$S21")"
if printf '%s' "$out" | grep -qE 'units: 1/2 chartered .* \(1 glob-chartered\)'; then
  ok "glob token: clHVAC* charters clHVACChiller as glob-chartered, not unrelated"
else
  no "glob token FAILED" "out=$out"
fi

# ---- 22. whitespace-split: a multi-identifier backtick span charters each identifier
S22="$ROOT/s22"; C22="$ROOT/c22"
mk_unit "$S22" "honIrmConfig" "A.java"
mk_focuses "$C22" '| kitControl | active | | gate: `check-coverage.py honeywellSpyderTool honIrmConfig` |'
out="$(run "$C22" --subject "$S22")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "whitespace-split: honIrmConfig resolved from a multi-identifier span"
else
  no "whitespace-split FAILED" "out=$out"
fi

# ---- 23. unresolved RESEARCH-STATE reference: WARNs, never silently drops the ambiguity
S23="$ROOT/s23"; C23="$ROOT/c23"
mk_unit "$S23" "mod_a" "Alpha.java"
mk_focuses "$C23" '| gone | active | RESEARCH-STATE-gone.md | never created |'
out="$(rune "$C23" --subject "$S23")"
if printf '%s' "$out" | grep -q 'unresolved RESEARCH-STATE references: 1' \
   && printf '%s' "$out" | grep -q 'WARN:.*RESEARCH-STATE-gone.md'; then
  ok "unresolved RESEARCH-STATE reference: declared count + WARN, not a silent drop"
else
  no "unresolved RESEARCH-STATE reference FAILED" "out=$out"
fi

# ---- 24. F3: comma-joined profile-suffix shorthand `<module>-rt,-wb` charters `<module>`
# (real corpus form: RESEARCH-STATE-framework-drivers.md:49 `opcUaServer-rt,-wb`)
S24="$ROOT/s24"; C24="$ROOT/c24"
mk_unit "$S24" "opcUaServer" "A.java"
mk_focuses "$C24" '| framework-drivers | stopped | RESEARCH-STATE-framework-drivers.md | driver survey |'
mk_state "$C24" "RESEARCH-STATE-framework-drivers.md" \
  'FD3 opcUaServer server-side exposure `opcUaServer-rt,-wb` (47 vf) COVERED -> B498'
out="$(run "$C24" --subject "$S24")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "F3: comma-joined profile-suffix shorthand (opcUaServer-rt,-wb) charters opcUaServer"
else
  no "F3 comma-joined profile-suffix FAILED" "out=$out"
fi

# ---- 25. R1 (round 3): bare camelCase module name inside a table row charters it — the real
# corpus's own gap/charter table format (RESEARCH-STATE-oem-honeywell-tail.md:58): a
# parenthesized, comma-separated, file-count-annotated bare-word list, never backtick-wrapped.
S25="$ROOT/s25"; C25="$ROOT/c25"
mk_unit "$S25" "honPlantControllerMigrator" "A.java"
mk_focuses "$C25" '| oem-honeywell-tail | stopped | RESEARCH-STATE-oem-honeywell-tail.md | OEM residue |'
mk_state "$C25" "RESEARCH-STATE-oem-honeywell-tail.md" \
  '| LOW-MED | U9 | Honeywell migrators — DELTA over B90 | honPlantControllerMigrator (68), honeywellModbusSmartSensor (25) | investigable | COVERED -> B250 |'
out="$(run "$C25" --subject "$S25")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "R1: bare camelCase word in a real gap-table row charters honPlantControllerMigrator"
else
  no "R1 bare-camelCase-in-table-row FAILED" "out=$out"
fi

# ---- 26. R1: bare-number-annotated comma list form (RESEARCH-STATE-oem-honeywell-tail.md:57)
S26="$ROOT/s26"; C26="$ROOT/c26"
mk_unit "$S26" "clStationUpgradeTool" "A.java"
mk_focuses "$C26" '| oem-honeywell-tail | stopped | RESEARCH-STATE-oem-honeywell-tail.md | Centraline residue |'
mk_state "$C26" "RESEARCH-STATE-oem-honeywell-tail.md" \
  '| MED | U8 | Centraline residue | 8 mods (clPrintout 24, clStationUpgradeTool 11, clProfile 1) | investigable | COVERED -> B249 |'
out="$(run "$C26" --subject "$S26")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "R1: bare-number-annotated comma list charters clStationUpgradeTool"
else
  no "R1 bare-number-list FAILED" "out=$out"
fi

# ---- 27. R1: a bare ALL-LOWERCASE word in a table row is a bare-mention, not confident
# unchartered AND not silently chartered (the real defect: zwave-wb, unformatted, in a table row)
S27="$ROOT/s27"; C27="$ROOT/c27"
mk_unit "$S27" "zwave" "A.java"
mk_focuses "$C27" '| wb-vendor-ux | active | RESEARCH-STATE-wb-vendor-ux.md | vendor WB survey |'
mk_state "$C27" "RESEARCH-STATE-wb-vendor-ux.md" \
  '| WV22 | zwave-wb (17 cls) - Z-Wave mesh wireless WB | MED | closed | B1102 |'
out="$(run "$C27" --subject "$S27")"
if printf '%s' "$out" | grep -qE 'units: 0/1 chartered' && printf '%s' "$out" | grep -qE '1 bare-mention'; then
  ok "R1: all-lowercase bare word (zwave) is bare-mention, neither chartered nor confident-unchartered"
else
  no "R1 bare-mention FAILED" "out=$out"
fi

# ---- 28. R1 negative control: a bare word appearing ONLY in a bullet-list line (not a table row)
# must NOT be captured by either the camelCase-charter or the bare-mention mechanism — mirrors the
# real RESEARCH-STATE.md:29 airFlowBalancer citation, deliberately excluded (prose, not a table row)
S28="$ROOT/s28"; C28="$ROOT/c28"
mk_unit "$S28" "airFlowBalancer" "A.java"
mk_focuses "$C28" '| some-focus | active | RESEARCH-STATE-some-focus.md | bullet-list only |'
mk_state "$C28" "RESEARCH-STATE-some-focus.md" \
  '- Covered blocks: B101 (airFlowBalancer/kitCat), B106 (honeywellSpyderTool)'
out="$(run "$C28" --subject "$S28")"
if printf '%s' "$out" | grep -qE 'units: 0/1 chartered' && ! printf '%s' "$out" | grep -qE '1 bare-mention'; then
  ok "R1 negative control: bullet-list-only mention stays plain unchartered, not bare-mention"
else
  no "R1 negative control FAILED (bullet-list line must not count as a table row)" "out=$out"
fi

# ---- 29. R3: `cat` missing from PATH must degrade, not silently read as an empty RESEARCH-STATE
TOOLSDIR_CAT="$ROOT/mini-path-cat"
mkdir -p "$TOOLSDIR_CAT"
for t in bash find grep sed awk sort wc tr mktemp basename head rm dirname; do
  ln -sf "$(command -v "$t")" "$TOOLSDIR_CAT/$t"
done
out="$(PATH="$TOOLSDIR_CAT" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'degraded: cat not found'; then
  ok "R3: missing cat -> exit 3, not a silent empty RESEARCH-STATE read"
else
  no "R3 cat degraded FAILED" "rc=$rc out=$out"
fi

# ---- 30. R3: `dirname` missing from PATH must degrade too
TOOLSDIR_DN="$ROOT/mini-path-dirname"
mkdir -p "$TOOLSDIR_DN"
for t in bash find grep sed awk sort wc tr mktemp basename head rm cat; do
  ln -sf "$(command -v "$t")" "$TOOLSDIR_DN/$t"
done
out="$(PATH="$TOOLSDIR_DN" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'degraded: dirname not found'; then
  ok "R3: missing dirname -> exit 3"
else
  no "R3 dirname degraded FAILED" "rc=$rc out=$out"
fi

echo ""

# ==========================================================================
# TEETH — mutant verification (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== --prove-teeth =="

  # ---- tooth (a): hardcode UNCHARTERED=0, anchored so it cannot also clobber
  # FAMILIES_UNCHARTERED= (which contains the same substring) — verifies the anchor itself too.
  echo "-- teeth-a: hardcode UNCHARTERED=0 (anchored); unchartered count must go red --"
  MUTANT_A="$ROOT/fpa.MUT-A.sh"
  if grep -q 'SENTINEL-A:' "$SUT"; then
    sed 's/^UNCHARTERED=.*/UNCHARTERED=0  # MUTATED-A/' "$SUT" > "$MUTANT_A"
    SA="$ROOT/sa"; CA="$ROOT/ca"
    mk_unit "$SA" "mod_a" "Alpha.java"
    mkdir -p "$CA"
    rout_a="$(bash "$SUT" "$CA" --subject "$SA" 2>/dev/null)"
    mout_a="$(bash "$MUTANT_A" "$CA" --subject "$SA" 2>/dev/null)"
    rfam="$(printf '%s' "$rout_a" | grep 'families:')"
    mfam="$(printf '%s' "$mout_a" | grep 'families:')"
    if printf '%s' "$rout_a" | grep -qE '0/1 chartered .* 1 unchartered' \
       && printf '%s' "$mout_a" | grep -qE '0/1 chartered .* 0 unchartered' \
       && [ "$rfam" = "$mfam" ]; then
      ok "teeth-a: original 1 unchartered; mutant 0 — bites, and the anchor does NOT touch families:"
    else
      no "teeth-a: mutation did not change unchartered count precisely" "orig=$rout_a mut=$mout_a"
    fi
  else
    no "teeth-a: SENTINEL-A: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (b): drop backtick-only restriction — scan raw cell prose for bare unit mentions
  echo "-- teeth-b: bare-prose mutant; bare mention must not charter (real fix does) --"
  MUTANT_B="$ROOT/fpa.MUT-B.sh"
  if grep -q 'SENTINEL-B:' "$SUT"; then
    sed "s#grep -oE '\`\[^\`\]+\`' \"\$TMP/row_cells.txt\" 2>/dev/null#cat \"\$TMP/row_cells.txt\" 2>/dev/null#" "$SUT" > "$MUTANT_B"
    SB="$ROOT/sb"; CB="$ROOT/cb"
    mk_unit "$SB" "mod_bare" "Alpha.java"
    mk_focuses "$CB" '| some-focus | active | | mod_bare |'
    rout_b="$(bash "$SUT" "$CB" --subject "$SB" 2>/dev/null)"
    mout_b="$(bash "$MUTANT_B" "$CB" --subject "$SB" 2>/dev/null)"
    if printf '%s' "$rout_b" | grep -qE '0/1 chartered' \
       && printf '%s' "$mout_b" | grep -qE '1/1 chartered'; then
      ok "teeth-b: original 0/1 (bare prose never counts); mutant 1/1 — bites"
    else
      no "teeth-b: mutation did not change charter count" "orig=$rout_b mut=$mout_b"
    fi
  else
    no "teeth-b: SENTINEL-B: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (c): split on '.' too -> reproduces the real Clock.schedule false charter
  echo "-- teeth-c: split-on-dot mutant; Clock.schedule must falsely charter 'schedule' --"
  MUTANT_C="$ROOT/fpa.MUT-C.sh"
  if grep -q 'SENTINEL-C:' "$SUT"; then
    sed "s#awk -F'\[/,\]' '{ for (i = 1; i <= NF; i++) print \$i }'#awk -F'[/,.]' '{ for (i = 1; i <= NF; i++) print \$i }'#" "$SUT" > "$MUTANT_C"
    SC="$ROOT/sc"; CC="$ROOT/cc"
    mk_unit "$SC" "schedule" "BWeeklySchedule.java"
    mk_focuses "$CC" '| build-kit-campaign8 | stopped | | the `Clock.schedule` delay/period floor |'
    rout_c="$(bash "$SUT" "$CC" --subject "$SC" 2>/dev/null)"
    mout_c="$(bash "$MUTANT_C" "$CC" --subject "$SC" 2>/dev/null)"
    if printf '%s' "$rout_c" | grep -qE '0/1 chartered' \
       && printf '%s' "$mout_c" | grep -qE '1/1 chartered'; then
      ok "teeth-c: original rejects Clock.schedule; dot-split mutant falsely charters — bites"
    else
      no "teeth-c: mutation did not reproduce the false charter" "orig=$rout_c mut=$mout_c"
    fi
  else
    no "teeth-c: SENTINEL-C: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (d): exact-token equality loosened to substring
  echo "-- teeth-d: substring mutant; 'modbus' must falsely charter via 'modbusCore' token --"
  MUTANT_D="$ROOT/fpa.MUT-D.sh"
  if grep -q 'SENTINEL-D:' "$SUT"; then
    sed 's/grep -qxF "\$mod"/grep -qF "\$mod"/' "$SUT" > "$MUTANT_D"
    SD="$ROOT/sd"; CD="$ROOT/cd"
    mk_unit "$SD" "modbus" "BModbusNetwork.java"
    mk_focuses "$CD" '| some-focus | active | | see `modbusCore` driver family |'
    rout_d="$(bash "$SUT" "$CD" --subject "$SD" 2>/dev/null)"
    mout_d="$(bash "$MUTANT_D" "$CD" --subject "$SD" 2>/dev/null)"
    if printf '%s' "$rout_d" | grep -qE '0/1 chartered' \
       && printf '%s' "$mout_d" | grep -qE '1/1 chartered'; then
      ok "teeth-d: original 0/1 (exact token); substring mutant 1/1 — bites"
    else
      no "teeth-d: mutation did not change charter count" "orig=$rout_d mut=$mout_d"
    fi
  else
    no "teeth-d: SENTINEL-D: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (e): family min-length-3 gate removed -> over-merges 1-2 char prefixes
  echo "-- teeth-e: family-gate mutant; short-prefix units must over-merge --"
  MUTANT_E="$ROOT/fpa.MUT-E.sh"
  if grep -q 'SENTINEL-E:' "$SUT"; then
    sed 's/if (length(k) >= 3) key = k/key = k/' "$SUT" > "$MUTANT_E"
    SE="$ROOT/se"; CE="$ROOT/ce"
    mk_unit "$SE" "aXray" "A.java"
    mk_unit "$SE" "aYankee" "B.java"
    mkdir -p "$CE"
    rout_e="$(bash "$SUT" "$CE" --subject "$SE" 2>/dev/null)"
    mout_e="$(bash "$MUTANT_E" "$CE" --subject "$SE" 2>/dev/null)"
    rfam="$(printf '%s' "$rout_e" | grep 'families:' | grep -oE '^[^ ]+ [0-9]+' | grep -oE '[0-9]+' | head -1)"
    mfam="$(printf '%s' "$mout_e" | grep 'families:' | grep -oE '^[^ ]+ [0-9]+' | grep -oE '[0-9]+' | head -1)"
    if [ "${rfam:-0}" -eq 2 ] && [ "${mfam:-0}" -eq 1 ]; then
      ok "teeth-e: original 2 families (a<3 chars, singletons); mutant merges to 1 — bites"
    else
      no "teeth-e: mutation did not change family count" "orig=$rout_e ($rfam) mut=$mout_e ($mfam)"
    fi
  else
    no "teeth-e: SENTINEL-E: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (f): unclassifiable-row gate loosened -> blank-identity row silently classified
  echo "-- teeth-f: unclassifiable-gate mutant; blank-identity row must silently classify --"
  MUTANT_F="$ROOT/fpa.MUT-F.sh"
  if grep -q 'SENTINEL-F:' "$SUT"; then
    sed 's/if (n < 2 || ident == "") { unclass++; next }/if (n < 1) { unclass++; next }/' "$SUT" > "$MUTANT_F"
    SF="$ROOT/sf"; CF="$ROOT/cf"
    mk_unit "$SF" "mod_a" "Alpha.java"
    mk_focuses "$CF" '|  | active | | ambito con `mod_a` pero sin identidad de focus |'
    rout_f="$(bash "$SUT" "$CF" --subject "$SF" 2>/dev/null)"
    mout_f="$(bash "$MUTANT_F" "$CF" --subject "$SF" 2>/dev/null)"
    if printf '%s' "$rout_f" | grep -q 'FOCUSES.md rows: 0 classified, 1 unclassifiable' \
       && printf '%s' "$mout_f" | grep -q 'FOCUSES.md rows: 1 classified, 0 unclassifiable'; then
      ok "teeth-f: original counts blank-identity row unclassifiable; mutant classifies it — bites"
    else
      no "teeth-f: mutation did not change row classification" "orig=$rout_f mut=$mout_f"
    fi
  else
    no "teeth-f: SENTINEL-F: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (g) (F6): row-shape gate loosened back to bare index($0,"|")
  echo "-- teeth-g (F6): row-shape mutant; a prose line with '|' must be miscounted as a row --"
  MUTANT_G="$ROOT/fpa.MUT-G.sh"
  if grep -q 'SENTINEL-ROW:' "$SUT"; then
    sed 's#if (\$0 !~ /\^\[ \\t\]\*\\|/) next#if (index($0, "|") == 0) next#' "$SUT" > "$MUTANT_G"
    SG="$ROOT/sg"; CG="$ROOT/cg"
    mk_unit "$SG" "mod_a" "Alpha.java"
    mkdir -p "$CG"
    {
      printf '| Focus | Estado | RESEARCH-STATE | Ambito |\n'
      printf '|---|---|---|---|\n'
      printf 'prose line with bit48=ADMIN_READ|ADMIN_WRITE embedded, not a table row\n'
      printf '| real-focus | active | | scope mentions `mod_a` |\n'
    } > "$CG/FOCUSES.md"
    rout_g="$(bash "$SUT" "$CG" --subject "$SG" 2>/dev/null)"
    mout_g="$(bash "$MUTANT_G" "$CG" --subject "$SG" 2>/dev/null)"
    if printf '%s' "$rout_g" | grep -q '1 classified, 0 unclassifiable' \
       && ! printf '%s' "$mout_g" | grep -q '1 classified, 0 unclassifiable'; then
      ok "teeth-g: original excludes the prose-with-pipe line; mutant miscounts it — bites"
    else
      no "teeth-g: mutation did not change row classification" "orig=$rout_g mut=$mout_g"
    fi
  else
    no "teeth-g: SENTINEL-ROW: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (h): dependency probe removed -> a missing PATH tool no longer degrades
  echo "-- teeth-h: drop dependency-probe loop body; missing tool must silently proceed --"
  MUTANT_H="$ROOT/fpa.MUT-H.sh"
  if grep -q 'SENTINEL-H:' "$SUT"; then
    awk '
      /# SENTINEL-H:/ { print; getline; print "  : # MUTATED-H (probe body dropped)"; skip=1; next }
      skip && /^  fi$/ { skip=0; next }
      skip { next }
      { print }
    ' "$SUT" > "$MUTANT_H"
    TOOLSDIR_H="$ROOT/mini-path-h"
    mkdir -p "$TOOLSDIR_H"
    for t in bash find grep sed awk sort wc tr mktemp basename head rm; do
      [ "$t" = "awk" ] && continue
      ln -sf "$(command -v "$t")" "$TOOLSDIR_H/$t"
    done
    rc_r=0; rc_m=0
    PATH="$TOOLSDIR_H" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_r=$?
    PATH="$TOOLSDIR_H" bash "$MUTANT_H" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_m=$?
    if [ "$rc_r" -eq 3 ] && [ "$rc_m" -ne 3 ]; then
      ok "teeth-h: original exits 3 (degraded, awk missing); mutant does not — bites"
    else
      no "teeth-h: mutation did not change degraded behavior" "rc_r=$rc_r rc_m=$rc_m"
    fi
  else
    no "teeth-h: SENTINEL-H: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (i) (F1, headline): disable RESEARCH-STATE resolution entirely
  echo "-- teeth-i (F1): RESEARCH-STATE-disabled mutant; the headline regression must reproduce --"
  MUTANT_I="$ROOT/fpa.MUT-I.sh"
  if grep -q 'STATE_RESOLVED=0' "$SUT"; then
    sed 's/if \[ -f "\$sfile" \] && \[ -r "\$sfile" \]; then/if false; then/' "$SUT" > "$MUTANT_I"
    SI="$ROOT/si"; CI="$ROOT/ci"
    mk_unit "$SI" "modbusCore" "BModbusNetwork.java"
    mk_focuses "$CI" '| modbus | active | RESEARCH-STATE-modbus.md | the Modbus driver (no module names here) |'
    mk_state "$CI" "RESEARCH-STATE-modbus.md" '`modbusCore-rt` root COVERED -> B294'
    rout_i="$(bash "$SUT" "$CI" --subject "$SI" 2>/dev/null)"
    mout_i="$(bash "$MUTANT_I" "$CI" --subject "$SI" 2>/dev/null)"
    if printf '%s' "$rout_i" | grep -qE '1/1 chartered' \
       && printf '%s' "$mout_i" | grep -qE '0/1 chartered'; then
      ok "teeth-i: original resolves RESEARCH-STATE charter; mutant reproduces the F1 false negative — bites"
    else
      no "teeth-i: mutation did not reproduce F1" "orig=$rout_i mut=$mout_i"
    fi
  else
    no "teeth-i: RESEARCH-STATE resolution anchor not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (j): whitespace-split stage removed
  echo "-- teeth-j: whitespace-split-removed mutant; multi-identifier span must lose interior tokens --"
  MUTANT_J="$ROOT/fpa.MUT-J.sh"
  if grep -q "awk '{ for (i = 1; i <= NF; i++) print \$i }' \\\\" "$SUT"; then
    awk '
      /awk .\{ for \(i = 1; i <= NF; i\+\+\) print \$i \}. \\$/ { getline; next }
      { print }
    ' "$SUT" > "$MUTANT_J"
    SJ="$ROOT/sj"; CJ="$ROOT/cj"
    mk_unit "$SJ" "honIrmConfig" "A.java"
    mk_focuses "$CJ" '| kitControl | active | | gate: `check-coverage.py honeywellSpyderTool honIrmConfig` |'
    rout_j="$(bash "$SUT" "$CJ" --subject "$SJ" 2>/dev/null)"
    mout_j="$(bash "$MUTANT_J" "$CJ" --subject "$SJ" 2>/dev/null)"
    if printf '%s' "$rout_j" | grep -qE '1/1 chartered' \
       && printf '%s' "$mout_j" | grep -qE '0/1 chartered'; then
      ok "teeth-j: original resolves honIrmConfig via whitespace-split; mutant loses it — bites"
    else
      no "teeth-j: mutation did not change charter count" "orig=$rout_j mut=$mout_j"
    fi
  else
    no "teeth-j: whitespace-split anchor not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (k): profile-suffix expansion disabled
  echo "-- teeth-k: profile-suffix-disabled mutant; <module>-wb must stop chartering <module> --"
  MUTANT_K="$ROOT/fpa.MUT-K.sh"
  if grep -q 'plain_tokens_suffix.txt' "$SUT"; then
    sed 's#sort -u "\$TMP/plain_tokens_base.txt" "\$TMP/plain_tokens_suffix.txt" "\$TMP/bare_camel_tokens.txt" > "\$TMP/charter_tokens.txt"#sort -u "$TMP/plain_tokens_base.txt" "$TMP/bare_camel_tokens.txt" > "$TMP/charter_tokens.txt"#' "$SUT" > "$MUTANT_K"
    SK="$ROOT/sk"; CK="$ROOT/ck"
    mk_unit "$SK" "clCBus" "A.java"
    mk_focuses "$CK" '| wb-vendor-ux | active | RESEARCH-STATE-wb-vendor-ux.md | vendor WB survey |'
    mk_state "$CK" "RESEARCH-STATE-wb-vendor-ux.md" 'Archetype surveyed: `clCBus-wb` widgets'
    rout_k="$(bash "$SUT" "$CK" --subject "$SK" 2>/dev/null)"
    mout_k="$(bash "$MUTANT_K" "$CK" --subject "$SK" 2>/dev/null)"
    if printf '%s' "$rout_k" | grep -qE '1/1 chartered' \
       && printf '%s' "$mout_k" | grep -qE '0/1 chartered'; then
      ok "teeth-k: original expands clCBus-wb -> clCBus; mutant does not — bites"
    else
      no "teeth-k: mutation did not change charter count" "orig=$rout_k mut=$mout_k"
    fi
  else
    no "teeth-k: profile-suffix anchor not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (l): glob matching disabled
  echo "-- teeth-l: glob-matching-disabled mutant; clHVAC* must stop chartering clHVACChiller --"
  MUTANT_L="$ROOT/fpa.MUT-L.sh"
  if grep -q 'SENTINEL-G:' "$SUT"; then
    sed "s#elif \[ -s \"\$TMP/glob_tokens.txt\" \]; then#elif false; then#" "$SUT" > "$MUTANT_L"
    SL="$ROOT/sl"; CL="$ROOT/cl"
    mk_unit "$SL" "clHVACChiller" "A.java"
    mk_focuses "$CL" '| kitControl | active | | control HVAC libs (`clHVAC*`) |'
    rout_l="$(bash "$SUT" "$CL" --subject "$SL" 2>/dev/null)"
    mout_l="$(bash "$MUTANT_L" "$CL" --subject "$SL" 2>/dev/null)"
    if printf '%s' "$rout_l" | grep -qE '1/1 chartered' \
       && printf '%s' "$mout_l" | grep -qE '0/1 chartered'; then
      ok "teeth-l: original glob-charters clHVACChiller; mutant does not — bites"
    else
      no "teeth-l: mutation did not change charter count" "orig=$rout_l mut=$mout_l"
    fi
  else
    no "teeth-l: SENTINEL-G: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (m) (F7): --depth integer validation removed
  echo "-- teeth-m (F7): depth-validation-removed mutant; --depth abc must stop exiting 2 --"
  MUTANT_M="$ROOT/fpa.MUT-M.sh"
  if grep -q "FATAL: --depth must be a non-negative integer" "$SUT"; then
    sed "s/^  ''|\*\[!0-9\]\*) printf 'FATAL: --depth.*/  *) : # MUTATED-M no-op ;;/" "$SUT" > "$MUTANT_M"
    rc_r=0; rc_m=0
    bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" --depth abc >/dev/null 2>&1 || rc_r=$?
    bash "$MUTANT_M" "$ROOT/corpus" --subject "$ROOT/s2" --depth abc >/dev/null 2>&1 || rc_m=$?
    if [ "$rc_r" -eq 2 ] && [ "$rc_m" -ne 2 ]; then
      ok "teeth-m: original exits 2 on --depth abc; mutant does not — bites"
    else
      no "teeth-m: mutation did not change exit behavior" "rc_r=$rc_r rc_m=$rc_m"
    fi
  else
    no "teeth-m: --depth validation anchor not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (n) (R1, round 3): camelCase internal-uppercase-or-digit gate removed
  echo "-- teeth-n (R1): camelCase-gate mutant; a bare LOWERCASE table-row word must falsely charter --"
  MUTANT_N="$ROOT/fpa.MUT-N.sh"
  if grep -q 'SENTINEL-CAMEL:' "$SUT"; then
    sed "s#grep -E '\[A-Z0-9\]' \"\$TMP/bare_words_raw.txt\" 2>/dev/null#cat \"\$TMP/bare_words_raw.txt\" 2>/dev/null#" "$SUT" > "$MUTANT_N"
    SN="$ROOT/sn"; CN="$ROOT/cn"
    mk_unit "$SN" "zwave" "A.java"
    mk_focuses "$CN" '| wb-vendor-ux | active | RESEARCH-STATE-wb-vendor-ux.md | vendor WB survey |'
    mk_state "$CN" "RESEARCH-STATE-wb-vendor-ux.md" \
      '| WV22 | zwave-wb (17 cls) - Z-Wave mesh wireless WB | MED | closed | B1102 |'
    rout_n="$(bash "$SUT" "$CN" --subject "$SN" 2>/dev/null)"
    mout_n="$(bash "$MUTANT_N" "$CN" --subject "$SN" 2>/dev/null)"
    if printf '%s' "$rout_n" | grep -qE '0/1 chartered' \
       && printf '%s' "$mout_n" | grep -qE '1/1 chartered'; then
      ok "teeth-n: original never charters bare-lowercase zwave; mutant does — bites"
    else
      no "teeth-n: mutation did not change charter count" "orig=$rout_n mut=$mout_n"
    fi
  else
    no "teeth-n: SENTINEL-CAMEL: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (o) (R1, round 3): bare-mention downgrade removed — reverts to pre-round-3
  # always-unchartered behavior for a bare-lowercase table-row mention.
  echo "-- teeth-o (R1): bare-mention-removed mutant; zwave must fall back to plain unchartered --"
  MUTANT_O="$ROOT/fpa.MUT-O.sh"
  if grep -q 'SENTINEL-BAREMENTION:' "$SUT"; then
    sed 's/if grep -qxF "\$mod" "\$TMP\/bare_lowercase_tokens.txt" 2>\/dev\/null; then/if false; then/' "$SUT" > "$MUTANT_O"
    SO="$ROOT/so"; CO="$ROOT/co"
    mk_unit "$SO" "zwave" "A.java"
    mk_focuses "$CO" '| wb-vendor-ux | active | RESEARCH-STATE-wb-vendor-ux.md | vendor WB survey |'
    mk_state "$CO" "RESEARCH-STATE-wb-vendor-ux.md" \
      '| WV22 | zwave-wb (17 cls) - Z-Wave mesh wireless WB | MED | closed | B1102 |'
    rout_o="$(bash "$SUT" "$CO" --subject "$SO" 2>/dev/null)"
    mout_o="$(bash "$MUTANT_O" "$CO" --subject "$SO" 2>/dev/null)"
    if printf '%s' "$rout_o" | grep -qE '1 bare-mention' \
       && ! printf '%s' "$mout_o" | grep -qE '1 bare-mention'; then
      ok "teeth-o: original reports zwave as bare-mention; mutant reverts to silent unchartered — bites"
    else
      no "teeth-o: mutation did not change bare-mention count" "orig=$rout_o mut=$mout_o"
    fi
  else
    no "teeth-o: SENTINEL-BAREMENTION: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (p) (R3, round 3): `cat` dropped from the dependency probe
  echo "-- teeth-p (R3): cat-probe-removed mutant; a missing cat must stop degrading --"
  MUTANT_P="$ROOT/fpa.MUT-P.sh"
  if grep -q 'find awk grep sort sed wc tr mktemp basename head rm cat dirname' "$SUT"; then
    sed 's/find awk grep sort sed wc tr mktemp basename head rm cat dirname/find awk grep sort sed wc tr mktemp basename head rm dirname/' "$SUT" > "$MUTANT_P"
    TOOLSDIR_P="$ROOT/mini-path-p"
    mkdir -p "$TOOLSDIR_P"
    for t in bash find grep sed awk sort wc tr mktemp basename head rm dirname; do
      ln -sf "$(command -v "$t")" "$TOOLSDIR_P/$t"
    done
    rc_r=0; rc_m=0
    PATH="$TOOLSDIR_P" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_r=$?
    PATH="$TOOLSDIR_P" bash "$MUTANT_P" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_m=$?
    if [ "$rc_r" -eq 3 ] && [ "$rc_m" -ne 3 ]; then
      ok "teeth-p: original exits 3 (degraded, cat missing); mutant does not — bites"
    else
      no "teeth-p: mutation did not change degraded behavior" "rc_r=$rc_r rc_m=$rc_m"
    fi
  else
    no "teeth-p: dependency-probe list anchor not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (q) (R3, round 3): `dirname` dropped from the dependency probe
  echo "-- teeth-q (R3): dirname-probe-removed mutant; a missing dirname must stop degrading --"
  MUTANT_Q="$ROOT/fpa.MUT-Q.sh"
  if grep -q 'find awk grep sort sed wc tr mktemp basename head rm cat dirname' "$SUT"; then
    sed 's/find awk grep sort sed wc tr mktemp basename head rm cat dirname/find awk grep sort sed wc tr mktemp basename head rm cat/' "$SUT" > "$MUTANT_Q"
    TOOLSDIR_Q="$ROOT/mini-path-q"
    mkdir -p "$TOOLSDIR_Q"
    for t in bash find grep sed awk sort wc tr mktemp basename head rm cat; do
      ln -sf "$(command -v "$t")" "$TOOLSDIR_Q/$t"
    done
    rc_r=0; rc_m=0
    PATH="$TOOLSDIR_Q" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_r=$?
    PATH="$TOOLSDIR_Q" bash "$MUTANT_Q" "$ROOT/corpus" --subject "$ROOT/s2" >/dev/null 2>&1 || rc_m=$?
    if [ "$rc_r" -eq 3 ] && [ "$rc_m" -ne 3 ]; then
      ok "teeth-q: original exits 3 (degraded, dirname missing); mutant does not — bites"
    else
      no "teeth-q: mutation did not change degraded behavior" "rc_r=$rc_r rc_m=$rc_m"
    fi
  else
    no "teeth-q: dependency-probe list anchor not found in SUT (cannot anchor mutation)"
  fi

  echo ""
fi

# ---------- footer (run-all.sh's exact aggregator contract: this exact regex,
# as the LAST matching line — see run-all.sh's `summary_re`)
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
