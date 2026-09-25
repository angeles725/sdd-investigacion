#!/usr/bin/env bash
# focus-partition-audit.test.sh — RED-FIRST harness for focus-partition-audit.sh.
#
# Tests: absent subject (exit 1), empty subject, FOCUSES.md absent/empty/no-match, unclassifiable
# rows, backtick-exact charter, '/'-split path-token charter, false-positive rejection
# (Clock.schedule must not charter "schedule"), exact-token (no substring) charter, family
# grouping edges (first/middle/last/single), --top ranking, degraded (missing PATH tool).
# Teeth (--prove-teeth): (a) hardcoded UNCHARTERED=0, (b) drop backtick-only restriction
# (bare-prose charter — the core defect this tool exists to prevent), (c) split on '.' too
# (reproduces the real Clock.schedule false charter), (d) exact-token loosened to substring,
# (e) family min-length-3 gate removed, (f) unclassifiable-row gate loosened, (h) dependency
# probe removed.
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
    printf '| Focus | Estado | Ambito |\n'
    printf '|---|---|---|\n'
    for line; do printf '%s\n' "$line"; done
  } > "$dir/FOCUSES.md"
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

# ---- 3. FOCUSES.md absent (default path) -> focuses:absent-input, everything unchartered
S3="$ROOT/s3"; C3="$ROOT/c3"
mk_unit "$S3" "mod_a" "Alpha.java"
mkdir -p "$C3"   # corpus-dir exists but no FOCUSES.md
out="$(run "$C3" --subject "$S3")"
if printf '%s' "$out" | grep -q 'focuses: absent-input' \
   && printf '%s' "$out" | grep -qE 'units: 0/1 chartered'; then
  ok "FOCUSES.md absent: absent-input + unit reported unchartered (not a silent zero)"
else
  no "FOCUSES.md absent: expected absent-input + 0/1 chartered" "out=$out"
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
mk_focuses "$C5" '| module-mechanics | active | plain prose scope, no code spans |'
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
  '|  | active | ambito con `mod_a` pero sin identidad de focus |' \
  '| real-focus | active | scope mentions `mod_a` too |'
out="$(run "$C6" --subject "$S6")"
if printf '%s' "$out" | grep -q 'FOCUSES.md rows: 1 classified, 1 unclassifiable'; then
  ok "unclassifiable row: blank-identity row counted separately, not merged into classified"
else
  no "unclassifiable row: expected 1 classified, 1 unclassifiable" "out=$out"
fi

# ---- 7. backtick-exact charter: `mod_a` in a classified row charters unit mod_a
S7="$ROOT/s7"; C7="$ROOT/c7"
mk_unit "$S7" "mod_a" "Alpha.java"
mk_unit "$S7" "mod_b" "Beta.java"
mk_focuses "$C7" '| some-focus | active | scope covers `mod_a` mechanics |'
out="$(run "$C7" --subject "$S7")"
if printf '%s' "$out" | grep -qE 'units: 1/2 chartered'; then
  ok "backtick-exact charter: mod_a chartered, mod_b unchartered"
else
  no "backtick-exact charter: expected 1/2 chartered" "out=$out"
fi

# ---- 8. '/'-split path-token charter: `organized/mod_a/Foo.java` charters mod_a
S8="$ROOT/s8"; C8="$ROOT/c8"
mk_unit "$S8" "mod_a" "Alpha.java"
mk_focuses "$C8" '| some-focus | active | evidence path `organized/mod_a/Foo.java` |'
out="$(run "$C8" --subject "$S8")"
if printf '%s' "$out" | grep -qE 'units: 1/1 chartered'; then
  ok "path-token charter: organized/mod_a/... in a backtick span charters mod_a"
else
  no "path-token charter: expected 1/1 chartered" "out=$out"
fi

# ---- 9. false-positive rejection: Clock.schedule (real corpus defect) must not charter "schedule"
S9="$ROOT/s9"; C9="$ROOT/c9"
mk_unit "$S9" "schedule" "BWeeklySchedule.java"
mk_focuses "$C9" '| build-kit-campaign8 | stopped | the `Clock.schedule` delay/period floor |'
out="$(run "$C9" --subject "$S9")"
if printf '%s' "$out" | grep -qE 'units: 0/1 chartered'; then
  ok "false-positive rejection: Clock.schedule does not falsely charter module 'schedule'"
else
  no "false-positive rejection FAILED: Clock.schedule falsely charters 'schedule'" "out=$out"
fi

# ---- 10. exact-token equality: `modbus` backtick span must not charter unit "modbusCore"
S10="$ROOT/s10"; C10="$ROOT/c10"
mk_unit "$S10" "modbusCore" "BModbusNetwork.java"
mk_focuses "$C10" '| some-focus | active | see `modbus` driver family |'
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
# 2 families expected: "lon" (3 members, all unchartered) and "ZetaUnit" (1 member, unchartered)
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
  real="$(command -v "$t")"
  ln -sf "$real" "$TOOLSDIR/$t"
done
# deliberately omit awk and sort from the minimal PATH
out="$(PATH="$TOOLSDIR" bash "$SUT" "$ROOT/corpus" --subject "$ROOT/s2" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'degraded:'; then
  ok "degraded: missing PATH tool -> exit 3 + typed degraded message"
else
  no "degraded state FAILED" "rc=$rc out=$out"
fi

# ==========================================================================
# TEETH — mutant verification (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== --prove-teeth =="

  # ---- tooth (a): hardcode UNCHARTERED=0
  echo "-- teeth-a: hardcode UNCHARTERED=0; unchartered count must go red --"
  MUTANT_A="$ROOT/fpa.MUT-A.sh"
  if grep -q 'SENTINEL-A:' "$SUT"; then
    sed 's/UNCHARTERED=.*/UNCHARTERED=0  # MUTATED-A/' "$SUT" > "$MUTANT_A"
    SA="$ROOT/sa"; CA="$ROOT/ca"
    mk_unit "$SA" "mod_a" "Alpha.java"
    mkdir -p "$CA"
    rout_a="$(bash "$SUT" "$CA" --subject "$SA" 2>/dev/null)"
    mout_a="$(bash "$MUTANT_A" "$CA" --subject "$SA" 2>/dev/null)"
    if printf '%s' "$rout_a" | grep -qE '0/1 chartered .* 1 unchartered' \
       && printf '%s' "$mout_a" | grep -qE '0/1 chartered .* 0 unchartered'; then
      ok "teeth-a: original 1 unchartered; mutant 0 — bites"
    else
      no "teeth-a: mutation did not change unchartered count" "orig=$rout_a mut=$mout_a"
    fi
  else
    no "teeth-a: SENTINEL-A: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (b): drop backtick-only restriction — scan raw cell prose for bare unit mentions
  echo "-- teeth-b: bare-prose mutant; bare mention must not charter (real fix does) --"
  MUTANT_B="$ROOT/fpa.MUT-B.sh"
  if grep -q 'SENTINEL-B:' "$SUT"; then
    # Mutant: also feed raw row_cells.txt lines (not just backtick spans) into the token stream.
    sed "s#grep -oE '\`\[^\`\]+\`' \"\$TMP/row_cells.txt\" 2>/dev/null#cat \"\$TMP/row_cells.txt\" 2>/dev/null#" "$SUT" > "$MUTANT_B"
    SB="$ROOT/sb"; CB="$ROOT/cb"
    mk_unit "$SB" "mod_bare" "Alpha.java"
    # whole cell is a bare identifier-shaped word (no backticks): isolates the backtick-boundary
    # check from the identifier-shape filter, which alone already rejects space-bearing prose
    mk_focuses "$CB" '| some-focus | active | mod_bare |'
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
    sed "s#awk -F'/' '{ for (i = 1; i <= NF; i++) print \$i }'#awk -F'[/.]' '{ for (i = 1; i <= NF; i++) print \$i }'#" "$SUT" > "$MUTANT_C"
    SC="$ROOT/sc"; CC="$ROOT/cc"
    mk_unit "$SC" "schedule" "BWeeklySchedule.java"
    mk_focuses "$CC" '| build-kit-campaign8 | stopped | the `Clock.schedule` delay/period floor |'
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
  # Direction matters: the needle (unit basename) must be SHORTER than the haystack (a charter
  # token) for -x removal to matter — grep -F substring containment cannot find a longer needle
  # inside a shorter haystack line either way.
  echo "-- teeth-d: substring mutant; 'modbus' must falsely charter via 'modbusCore' token --"
  MUTANT_D="$ROOT/fpa.MUT-D.sh"
  if grep -q 'SENTINEL-D:' "$SUT"; then
    sed 's/grep -qxF "\$mod"/grep -qF "\$mod"/' "$SUT" > "$MUTANT_D"
    SD="$ROOT/sd"; CD="$ROOT/cd"
    mk_unit "$SD" "modbus" "BModbusNetwork.java"
    mk_focuses "$CD" '| some-focus | active | see `modbusCore` driver family |'
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
    mk_focuses "$CF" '|  | active | ambito con `mod_a` pero sin identidad de focus |'
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
    for t in bash find grep sed awk sort; do
      # deliberately omit ONE (awk) again to prove the probe normally catches it
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

fi

# ---------- footer (run-all.sh's exact aggregator contract: this exact regex,
# as the LAST matching line — see run-all.sh's `summary_re`)
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
