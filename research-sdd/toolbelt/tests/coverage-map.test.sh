#!/usr/bin/env bash
# coverage-map.test.sh — RED-FIRST harness for coverage-map.sh.
#
# Tests: absent subject (exit 1), empty subject, zero block files, zero citations,
# ambiguity exclusion, word-boundary citation, path-token citation, top-N ranking,
# short basenames, always-print lines, --exclude-file, --exclude (command-line).
# Teeth (--prove-teeth): (a) hardcoded UNCITED=0, (b) ambiguity exclusion removed,
# (c) substring vs word-boundary on ext-bearing token, (d) bare-stem instead of ext-
# bearing token (METHODOLOGY §3 core defect), (e) excluded-by-declaration line silenced,
# (f) loosen path-token to bare dir — class-file extension required.
#
# Usage: coverage-map.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../coverage-map.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

run() { bash "$SUT" "$@" 2>/dev/null; }
rune() { bash "$SUT" "$@" 2>&1; }  # include stderr

echo "== coverage-map.test.sh =="

# ---------- helpers: build fixture trees
mk_corpus() {
  # mk_corpus <dir> <block-filename> <content>
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/$2"
}
mk_unit() {
  # mk_unit <subject> <unit-name> [file1 file2 ...]
  local subj="$1" unit="$2"; shift 2
  mkdir -p "$subj/$unit"
  for f; do touch "$subj/$unit/$f"; done
}

# ---- 1. absent subject → exit 1 + typed message
out="$(rune "$ROOT/corpus" --subject "$ROOT/absent_subject" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'absent-input'; then
  ok "absent subject: exit 1 + absent-input message"
else
  no "absent subject: expected exit 1 + absent-input" "rc=$rc out=$out"
fi

# ---- 2. subject exists but contains no files with listed ext
S2="$ROOT/s2"; C2="$ROOT/c2"
mk_unit "$S2" "mod_alpha" "README.txt"
mk_corpus "$C2" "proj-bloque1.md" "some text"
out="$(run "$C2" --subject "$S2")"
if printf '%s' "$out" | grep -q 'empty-input'; then
  ok "empty subject (no .java): empty-input message"
else
  no "empty subject: expected empty-input" "out=$out"
fi

# ---- 3. zero block files in corpus → corpus empty-input state
S3="$ROOT/s3"; C3="$ROOT/c3"
mk_unit "$S3" "mod_a" "Alpha.java"
mkdir -p "$C3"   # corpus exists but has no block files
touch "$C3/notes.txt"
out="$(run "$C3" --subject "$S3")"
if printf '%s' "$out" | grep -q 'corpus: empty-input'; then
  ok "zero block files: corpus empty-input state distinct from zero citations"
else
  no "zero block files: expected corpus empty-input" "out=$out"
fi

# ---- 4. zero citations → no-match line printed
S4="$ROOT/s4"; C4="$ROOT/c4"
mk_unit "$S4" "mod_a" "Alpha.java"
mk_corpus "$C4" "proj-bloque1.md" "nothing relevant here"
out="$(run "$C4" --subject "$S4")"
if printf '%s' "$out" | grep -q 'no-match'; then
  ok "zero citations: no-match line present"
else
  no "zero citations: no-match line missing" "out=$out"
fi

# ---- 5. ambiguous basenames excluded; cited module uses unique basename
# METHODOLOGY §3: citation writes the extension-bearing token, e.g. UniqueClass.java
S5="$ROOT/s5"; C5="$ROOT/c5"
mk_unit "$S5" "solo" "UniqueClass.java"
mk_unit "$S5" "alpha" "Shared.java"
mk_unit "$S5" "beta"  "Shared.java"
mk_corpus "$C5" "proj-bloque1.md" "Shared.java used here; also UniqueClass.java in context"
out="$(run "$C5" --subject "$S5")"
ambig_n="$(printf '%s' "$out" | grep 'ambiguous basenames excluded' | grep -oE '[0-9]+' | head -1)"
modules_line="$(printf '%s' "$out" | grep 'modules:')"
# Shared is ambiguous (2 modules), UniqueClass is unambiguous and cited
# solo → cited; alpha and beta → uncited (Shared excluded)
if [ "${ambig_n:-0}" -ge 1 ] \
   && printf '%s' "$modules_line" | grep -qE '1/3 cited'; then
  ok "ambiguity exclusion: Shared excluded; solo cited via UniqueClass.java"
else
  no "ambiguity exclusion" "ambig=$ambig_n modules_line=$modules_line"
fi

# ---- 6. word-boundary: Foo not cited by BarFoo mention (no Foo.java present either)
S6="$ROOT/s6"; C6="$ROOT/c6"
mk_unit "$S6" "solo" "Foo.java"
mk_corpus "$C6" "proj-bloque1.md" "BarFoo is the main class here"
out="$(run "$C6" --subject "$S6")"
if printf '%s' "$out" | grep -qE '0/1 cited'; then
  ok "ext-bearing: Foo not cited (no Foo.java in corpus, BarFoo irrelevant)"
else
  no "ext-bearing: Foo should NOT be cited" "out=$out"
fi

# ---- 7. extension-bearing citation: Widget.java IS cited when it appears with extension
S7="$ROOT/s7"; C7="$ROOT/c7"
mk_unit "$S7" "solo" "Widget.java"
mk_corpus "$C7" "proj-bloque1.md" "see Widget.java in the codebase"
out="$(run "$C7" --subject "$S7")"
if printf '%s' "$out" | grep -qE '1/1 cited'; then
  ok "ext-bearing citation: Widget.java (>=4 chars) is cited correctly"
else
  no "ext-bearing citation: Widget.java should be cited" "out=$out"
fi

# ---- 8. path-token citation: module name appearing as path component
S8="$ROOT/s8"; C8="$ROOT/c8"
mk_unit "$S8" "bacnetUtil" "BACnetDevice.java"
mk_corpus "$C8" "proj-bloque1.md" "see bacnetUtil/src/BACnetDevice.java for details"
out="$(run "$C8" --subject "$S8")"
if printf '%s' "$out" | grep -qE '1/1 cited'; then
  ok "path-token citation: bacnetUtil/ in corpus cites bacnetUtil module"
else
  no "path-token citation: expected 1/1 cited" "out=$out"
fi

# ---- 9. --top N ranks uncited modules by file count desc
S9="$ROOT/s9"; C9="$ROOT/c9"
mkdir -p "$S9/big" "$S9/small"
for i in $(seq 1 5); do touch "$S9/big/Class${i}.java"; done
touch "$S9/small/OneClass.java"
mk_corpus "$C9" "proj-bloque1.md" "nothing matching here"
out="$(run "$C9" --subject "$S9" --top 2)"
first_count="$(printf '%s' "$out" | grep -E '^[0-9]+' | head -1 | awk '{print $1}')"
if [ "${first_count:-0}" -eq 5 ]; then
  ok "--top N: big (5 files) ranks first, small (1 file) second"
else
  no "--top N: expected first row count=5" "first_count=${first_count:-none} out=$out"
fi

# ---- 10. short basenames (< 4 chars) excluded from index
# METHODOLOGY §3: citation token must be extension-bearing, so FooBar.java is cited, not Foo.java
S10="$ROOT/s10"; C10="$ROOT/c10"
mk_unit "$S10" "mod_a" "Foo.java"    # 3 chars → excluded from index
mk_unit "$S10" "mod_b" "FooBar.java" # 6 chars → included
mk_corpus "$C10" "proj-bloque1.md" "FooBar.java is a real class. Foo appears too."
out="$(run "$C10" --subject "$S10")"
# mod_b (FooBar.java) should be cited, mod_a's Foo is excluded (short → not indexed)
if printf '%s' "$out" | grep -qE '1/2 cited'; then
  ok "short basenames excluded: Foo (3 chars) not in index; FooBar.java cited"
else
  no "short basename exclusion" "out=$out"
fi

# ---- 11. always print ambiguous, excluded-by-declaration, and modules lines (even on no-match)
S11="$ROOT/s11"; C11="$ROOT/c11"
mk_unit "$S11" "mod_a" "Alpha.java"
mk_corpus "$C11" "proj-bloque1.md" "unrelated text"
out="$(run "$C11" --subject "$S11")"
if printf '%s' "$out" | grep -q 'ambiguous basenames excluded:' \
   && printf '%s' "$out" | grep -q 'excluded by declaration:' \
   && printf '%s' "$out" | grep -q 'modules:'; then
  ok "always-print: ambiguous + excluded-by-declaration + modules lines always present"
else
  no "always-print: missing required output lines" "out=$out"
fi

# ---- 12. --exclude-file drops units from denominator; line names the file
S12="$ROOT/s12"; C12="$ROOT/c12"
mk_unit "$S12" "appCore" "Main.java"
mk_unit "$S12" "vendorLib" "Helper.java"
mk_corpus "$C12" "proj-bloque1.md" "Main.java is the entry point"
EXCL12="$ROOT/excl12.txt"
printf 'vendorLib\n' > "$EXCL12"
out="$(run "$C12" --subject "$S12" --exclude-file "$EXCL12")"
excl_line="$(printf '%s' "$out" | grep 'excluded by declaration:')"
# vendorLib excluded: effective total=1, appCore cited via Main.java
if printf '%s' "$out" | grep -qE '1/1 cited' \
   && printf '%s' "$excl_line" | grep -q '1 unit' \
   && printf '%s' "$excl_line" | grep -q "$EXCL12"; then
  ok "--exclude-file: vendorLib excluded; appCore cited; declaration names file"
else
  no "--exclude-file: failed" "out=$out excl_line=$excl_line"
fi

# ---- 13. --exclude (command-line) drops unit; source shows command-line
S13="$ROOT/s13"; C13="$ROOT/c13"
mk_unit "$S13" "appMain" "Main.java"      # basename Main = 4 chars (≥4 → included in index)
mk_unit "$S13" "thirdParty" "Vendor.java"
mk_corpus "$C13" "proj-bloque1.md" "Main.java is the application entry point"
out="$(run "$C13" --subject "$S13" --exclude "thirdParty")"
excl_line13="$(printf '%s' "$out" | grep 'excluded by declaration:')"
if printf '%s' "$out" | grep -qE '1/1 cited' \
   && printf '%s' "$excl_line13" | grep -q '1 unit'; then
  ok "--exclude: thirdParty excluded from denominator; appMain cited"
else
  no "--exclude: failed" "out=$out excl_line=$excl_line13"
fi

# ---- 14. unreadable exclude file → WARN fires (§7 || true hole, fix #500)
# grep exits ≥2 when it cannot read the file; WARN must appear in stderr.
# Root guard: chmod 000 is ineffective when running as root.
S14="$ROOT/s14"; C14="$ROOT/c14"
mk_unit "$S14" "appMain" "AppEntry.java"
mk_corpus "$C14" "proj-bloque1.md" "AppEntry.java is the entry point"
EXCL14="$ROOT/excl14.txt"
printf 'vendorExcluded\n' > "$EXCL14"
chmod 000 "$EXCL14"
if [ "$(id -u)" -eq 0 ]; then
  ok "14-skip (running as root; chmod 000 does not prevent read — root can always read)"
else
  out14="$(rune "$C14" --subject "$S14" --exclude-file "$EXCL14")"
  if printf '%s' "$out14" | grep -q 'WARN: exclude-file read FAILED'; then
    ok "14. unreadable exclude file: WARN fires (not silently empty, #500)"
  else
    no "14. unreadable exclude file: expected WARN line, got none" "out=$out14"
  fi
  chmod 644 "$EXCL14"
fi

# ---- 15. all-comment exclude file (rc==1 benign) → no WARN, 0 exclusions
# grep -v '^#' exits 1 when all lines are comments; that is a legitimate empty set.
S15="$ROOT/s15"; C15="$ROOT/c15"
mk_unit "$S15" "appMain" "AppEntry.java"
mk_corpus "$C15" "proj-bloque1.md" "nothing matching here at all"
EXCL15="$ROOT/excl15.txt"
printf '# This line is a comment\n# Another comment\n\n' > "$EXCL15"
out15="$(rune "$C15" --subject "$S15" --exclude-file "$EXCL15")"
if ! printf '%s' "$out15" | grep -q 'WARN:' \
   && printf '%s' "$out15" | grep -q 'excluded by declaration: 0'; then
  ok "15. all-comment exclude file: no WARN, rc==1 treated as benign empty set"
else
  no "15. all-comment exclude file: unexpected WARN or wrong exclusion count" "out=$out15"
fi

# ---- 16. whitespace in corpus subdirectory path: space-named dir still read (#506)
# Pre-fix: xargs cat word-splits the space → block dropped → module uncited.
# Post-fix: while-read loop passes full path to cat → module cited.
S16="$ROOT/s16"; C16="$ROOT/c16"
mk_unit "$S16" "mod_a" "DistinctWidget.java"
mkdir -p "$C16/sub dir"   # directory whose name contains a space
printf 'DistinctWidget.java is referenced here\n' > "$C16/sub dir/proj-bloque1.md"
out16="$(run "$C16" --subject "$S16")"
if printf '%s' "$out16" | grep -qE '1/1 cited'; then
  ok "16. space in corpus subdir: DistinctWidget.java cited through space-path block"
else
  no "16. space in corpus subdir: expected 1/1 cited" "out=$out16"
fi

# ---- 17. unreadable block file: WARN fires to stderr, not silenced (§7 #506)
# Root guard: chmod 000 is not effective as root (owner can always read).
S17="$ROOT/s17"; C17="$ROOT/c17"
mk_unit "$S17" "mod_a" "AppCore.java"
mk_corpus "$C17" "proj-bloque1.md" "AppCore.java is the core class"
chmod 000 "$C17/proj-bloque1.md"
if [ "$(id -u)" -eq 0 ]; then
  ok "17-skip (running as root; chmod 000 does not prevent read)"
else
  out17="$(rune "$C17" --subject "$S17")"
  if printf '%s' "$out17" | grep -q 'WARN:.*block files unreadable'; then
    ok "17. unreadable block: WARN fires in stderr (#506)"
  else
    no "17. unreadable block: expected WARN, got none" "out=$out17"
  fi
  chmod 644 "$C17/proj-bloque1.md"
fi

# ==========================================================================
# TEETH — mutant verification (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: setting up shared fixture --"
  # Shared fixture: alpha (cited via UniqueAlpha.java), beta (uncited), Shared (ambiguous)
  # METHODOLOGY §3: corpus writes extension-bearing token UniqueAlpha.java
  ST="$ROOT/st"; CT="$ROOT/ct"
  mk_unit "$ST" "alpha" "UniqueAlpha.java" "Shared.java"
  mk_unit "$ST" "beta"  "UniqueBeta.java"  "Shared.java"
  mk_corpus "$CT" "proj-bloque1.md" "UniqueAlpha.java is referenced here"
  # Expected: alpha cited, beta uncited, Shared ambiguous (excluded)

  # ---- tooth (a): hardcode UNCITED=0 → uncited-count assertion goes red
  echo "-- teeth-a: hardcode UNCITED=0; uncited-count must go red --"
  MUTANT_A="$ROOT/cov-map.MUT-A.sh"
  # SENTINEL-A: count uncited
  if grep -q 'SENTINEL-A:' "$SUT"; then
    sed 's/UNCITED=.*/UNCITED=0  # MUTATED-A/' "$SUT" > "$MUTANT_A"
    mout_a="$(bash "$MUTANT_A" "$CT" --subject "$ST" 2>/dev/null)"
    if printf '%s' "$mout_a" | grep -qE '0 never cited'; then
      ok "teeth-a: UNCITED=0 mutant prints 0 never cited (assertion in real test would fail)"
    else
      no "teeth-a: mutant did not output 0 never cited" "out=$mout_a"
    fi
    # The real assertion: without mutation, uncited is 1
    rout_a="$(run "$CT" --subject "$ST" 2>/dev/null)"
    if printf '%s' "$rout_a" | grep -qE '1 never cited' \
       && ! printf '%s' "$mout_a" | grep -qE '1 never cited'; then
      ok "teeth-a: original prints 1 never cited; mutant prints 0 — bites"
    else
      no "teeth-a: mutation did not change uncited count" "orig=$rout_a mut=$mout_a"
    fi
  else
    no "teeth-a: SENTINEL-A: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (b): remove ambiguity exclusion → cited count moves
  # Mutant: sed changes '==1 &&' to '>=1 &&' in the unambig filter.
  echo "-- teeth-b: remove ambiguity exclusion; cited count must change --"
  MUTANT_B="$ROOT/cov-map.MUT-B.sh"
  # SENTINEL-B: exclude ambiguous basenames
  if grep -q 'SENTINEL-B:' "$SUT"; then
    # >=1 is always true; removes the single-module gate so Shared (ambiguous) survives
    sed 's/cnt.b.==1 &&/cnt[b]>=1 \&\&/' "$SUT" > "$MUTANT_B"
    # Corpus mentions Shared.java (the ambiguous basename) — extension-bearing
    CT_B="$ROOT/ctb"
    mk_corpus "$CT_B" "proj-bloque1.md" "Shared.java is referenced here"
    mout_b="$(bash "$MUTANT_B" "$CT_B" --subject "$ST" 2>/dev/null)"
    rout_b="$(run "$CT_B" --subject "$ST" 2>/dev/null)"
    mcited="$(printf '%s' "$mout_b" | grep 'modules:' | sed 's/modules: //' | cut -d'/' -f1 || true)"
    rcited="$(printf '%s' "$rout_b" | grep 'modules:' | sed 's/modules: //' | cut -d'/' -f1 || true)"
    if [ "${rcited:-x}" != "${mcited:-y}" ]; then
      ok "teeth-b: ambiguity exclusion removal changes cited count (orig=$rcited mut=$mcited)"
    else
      no "teeth-b: cited count unchanged after removing exclusion" "orig=$rout_b mut=$mout_b"
    fi
  else
    no "teeth-b: SENTINEL-B: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (c): substring instead of word-boundary on extension-bearing token
  # Uses SomeBase.java in corpus: Base.java is a substring of SomeBase.java.
  # With -w: no word boundary before B in SomeBase → no match → 0/1.
  # Without -w: Base.java IS a substring of SomeBase.java → match → 1/1.
  echo "-- teeth-c: remove -w from grep; SomeBase.java must falsely cite Base --"
  MUTANT_C="$ROOT/cov-map.MUT-C.sh"
  # SENTINEL-C: word-boundary grep on <basename>.<ext> tokens
  if grep -q 'SENTINEL-C:' "$SUT"; then
    sed 's/grep -qwFf/grep -qFf/' "$SUT" > "$MUTANT_C"
    SC="$ROOT/sc"; CC="$ROOT/cc"
    mk_unit "$SC" "solo" "Base.java"
    mk_corpus "$CC" "proj-bloque1.md" "SomeBase.java is the main class in the module"
    mout_c="$(bash "$MUTANT_C" "$CC" --subject "$SC" 2>/dev/null)"
    rout_c="$(run "$CC" --subject "$SC" 2>/dev/null)"
    if printf '%s' "$rout_c" | grep -qE '0/1 cited' \
       && printf '%s' "$mout_c" | grep -qE '1/1 cited'; then
      ok "teeth-c: original 0 cited (word-boundary); mutant (substring) 1 cited — bites"
    else
      no "teeth-c: mutation did not change citation" "orig=$rout_c mut=$mout_c"
    fi
  else
    no "teeth-c: SENTINEL-C: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (d): bare-stem mutant — match <basename> without extension
  # Fixture: module whose only basename is a generic English word (This, 4 chars).
  # Corpus mentions bare "This" (prose word) but NOT "This.java".
  # Original (fix 1): looks for This.java → not found → 0/1 cited.
  # Mutant (sed removes .ext from printf format): looks for bare This → found → 1/1 cited.
  echo "-- teeth-d: bare-stem mutant; This.java must not match bare This --"
  MUTANT_D="$ROOT/cov-map.MUT-D.sh"
  # SENTINEL-D: ext-bearing pattern (bare-stem mutant: remove extension)
  if grep -q 'SENTINEL-D:' "$SUT"; then
    # sed: change printf '%s.%s\n' to printf '%s\n' (second %s consumed by "$ext", ignored)
    sed 's/%s\.%s/%s/' "$SUT" > "$MUTANT_D"
    SD="$ROOT/sd"; CD="$ROOT/cd"
    mk_unit "$SD" "modal" "This.java"
    mk_corpus "$CD" "proj-bloque1.md" "This is the main dialog class here"
    rout_d="$(run "$CD" --subject "$SD" 2>/dev/null)"
    mout_d="$(bash "$MUTANT_D" "$CD" --subject "$SD" 2>/dev/null)"
    if printf '%s' "$rout_d" | grep -qE '0/1 cited' \
       && printf '%s' "$mout_d" | grep -qE '1/1 cited'; then
      ok "teeth-d: original not cited (no This.java in corpus); bare-stem mutant cited — bites"
    else
      no "teeth-d: bare-stem mutant did not change citation" \
         "orig=$(printf '%s' "$rout_d" | grep modules:) mut=$(printf '%s' "$mout_d" | grep modules:)"
    fi
  else
    no "teeth-d: SENTINEL-D: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (e): neuter excluded-by-declaration line → always-print invariant broken
  # Fixture uses --exclude to activate the exclusion path.
  # Original: prints "excluded by declaration:" line.
  # Mutant (printf silenced): line absent → §7 anti-silent-zero violated.
  echo "-- teeth-e: silence excluded-by-declaration; declaration must appear --"
  MUTANT_E="$ROOT/cov-map.MUT-E.sh"
  # SENTINEL-E: excluded-by-declaration line (must always appear; silence → tooth e)
  if grep -q 'SENTINEL-E:' "$SUT"; then
    sed 's/printf .excluded by declaration.*/: # MUTATED-E/' "$SUT" > "$MUTANT_E"
    SE="$ROOT/se"; CE="$ROOT/ce"
    mk_unit "$SE" "appMain" "AppMain.java"
    mk_unit "$SE" "vendorLib" "VendorTool.java"
    mk_corpus "$CE" "proj-bloque1.md" "some content here"
    rout_e="$(run "$CE" --subject "$SE" --exclude "vendorLib" 2>/dev/null)"
    mout_e="$(bash "$MUTANT_E" "$CE" --subject "$SE" --exclude "vendorLib" 2>/dev/null)"
    if printf '%s' "$rout_e" | grep -q 'excluded by declaration:' \
       && ! printf '%s' "$mout_e" | grep -q 'excluded by declaration:'; then
      ok "teeth-e: original prints excluded-by-declaration; mutant silences it — bites"
    else
      no "teeth-e: excluded-by-declaration line mutation did not bite" \
         "orig_has=$(printf '%s' "$rout_e" | grep -c 'excluded by declaration:' || true) mut_has=$(printf '%s' "$mout_e" | grep -c 'excluded by declaration:' || true)"
    fi
  else
    no "teeth-e: SENTINEL-E: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (f): path-token requires class-file extension — bare dir must NOT cite
  # Fixture: module bacnetDb (7 chars, ≥6); corpus mentions bare "bacnetDb/" (no .java).
  # Original (tightened): requires <mod>[-/]<path>.<ext> → 0/1 cited (bare dir no match).
  # Mutant (revert to bare dir): <mod>/ matches → 1/1 cited.
  echo "-- teeth-f: loosen path-token to bare dir; bacnetDb/ must not cite --"
  MUTANT_F="$ROOT/cov-map.MUT-F.sh"
  # SENTINEL-F: path-token requires class-file extension (loosen to bare dir to mutate)
  if grep -q 'SENTINEL-F:' "$SUT"; then
    sed 's#_ptok_pat=".*#_ptok_pat="(^|[^A-Za-z0-9_])${re_mod}/"#' "$SUT" > "$MUTANT_F"
    SF="$ROOT/sf"; CF="$ROOT/cf"
    mk_unit "$SF" "bacnetDb" "BACnetSchema.java"  # 7 chars, ≥6
    mk_corpus "$CF" "proj-bloque1.md" "see bacnetDb/ for the schema directory overview"
    rout_f="$(run "$CF" --subject "$SF" 2>/dev/null)"
    mout_f="$(bash "$MUTANT_F" "$CF" --subject "$SF" 2>/dev/null)"
    if printf '%s' "$rout_f" | grep -qE '0/1 cited' \
       && printf '%s' "$mout_f" | grep -qE '1/1 cited'; then
      ok "teeth-f: bare dir bacnetDb/ not cited (original); bare-dir mutant cites — bites"
    else
      no "teeth-f: path-token tightening mutation did not bite" \
         "orig=$(printf '%s' "$rout_f" | grep modules:) mut=$(printf '%s' "$mout_f" | grep modules:)"
    fi
  else
    no "teeth-f: SENTINEL-F: comment not found in SUT"
  fi

  # ---- tooth (g): unreadable exclude file → WARN fires; drop-WARN mutant → RED
  # Fixture: chmod 000 exclude file → grep exits ≥2.
  # Original fix (SENTINEL-G): captures rc, WARNs on ≥2.
  # Mutant: comments out the WARN printf → WARN disappears → RED.
  echo "-- teeth-g: unreadable file → WARN; drop-WARN mutant must go RED --"
  MUTANT_G="$ROOT/cov-map.MUT-G.sh"
  # SENTINEL-G: capture exclude-file read rc
  if grep -q 'SENTINEL-G:' "$SUT"; then
    SG="$ROOT/sg"; CG="$ROOT/cg"
    mk_unit "$SG" "appMain" "AppEntry.java"
    mk_corpus "$CG" "proj-bloque1.md" "nothing matches here"
    EXCL_G="$ROOT/excl_g.txt"
    printf 'vendorLib\n' > "$EXCL_G"
    chmod 000 "$EXCL_G"
    if [ "$(id -u)" -eq 0 ]; then
      ok "teeth-g: skipped (running as root; chmod 000 not effective for root)"
    else
      rout_g="$(bash "$SUT" "$CG" --subject "$SG" --exclude-file "$EXCL_G" 2>&1)"
      sed 's/printf.*exclude-file read FAILED.*/: # MUTATED-G/' "$SUT" > "$MUTANT_G"
      mout_g="$(bash "$MUTANT_G" "$CG" --subject "$SG" --exclude-file "$EXCL_G" 2>&1)"
      if printf '%s' "$rout_g" | grep -q 'WARN: exclude-file read FAILED' \
         && ! printf '%s' "$mout_g" | grep -q 'WARN: exclude-file read FAILED'; then
        ok "teeth-g: original WARNs on unreadable file; drop-WARN mutant silences it — bites"
      else
        no "teeth-g: drop-WARN mutant did not change WARN output" \
           "orig_warn=$(printf '%s' "$rout_g" | grep -c 'WARN:' || true) mut_warn=$(printf '%s' "$mout_g" | grep -c 'WARN:' || true)"
      fi
      chmod 644 "$EXCL_G"
    fi
  else
    no "teeth-g: SENTINEL-G: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (h): restore || true → rc ≥2 no longer captured → no WARN → RED
  # Mutant: replace '|| _excl_rc=$?' with '|| true' → _excl_rc stays 0 → WARN never fires.
  echo "-- teeth-h: revert || true; WARN must disappear for unreadable file → RED --"
  MUTANT_H="$ROOT/cov-map.MUT-H.sh"
  if grep -q 'SENTINEL-G:' "$SUT"; then
    SH_="$ROOT/sh2"; CH_="$ROOT/ch2"
    mk_unit "$SH_" "appMain" "AppEntry.java"
    mk_corpus "$CH_" "proj-bloque1.md" "nothing matches here"
    EXCL_H="$ROOT/excl_h.txt"
    printf 'vendorLib\n' > "$EXCL_H"
    chmod 000 "$EXCL_H"
    if [ "$(id -u)" -eq 0 ]; then
      ok "teeth-h: skipped (running as root; chmod 000 not effective for root)"
    else
      rout_h="$(bash "$SUT" "$CH_" --subject "$SH_" --exclude-file "$EXCL_H" 2>&1)"
      sed 's/|| _excl_rc=\$?/|| true/' "$SUT" > "$MUTANT_H"
      mout_h="$(bash "$MUTANT_H" "$CH_" --subject "$SH_" --exclude-file "$EXCL_H" 2>&1)"
      if printf '%s' "$rout_h" | grep -q 'WARN: exclude-file read FAILED' \
         && ! printf '%s' "$mout_h" | grep -q 'WARN: exclude-file read FAILED'; then
        ok "teeth-h: original WARNs; || true revert silences WARN — bites"
      else
        no "teeth-h: || true revert did not change WARN output" \
           "orig_warn=$(printf '%s' "$rout_h" | grep -c 'WARN:' || true) mut_warn=$(printf '%s' "$mout_h" | grep -c 'WARN:' || true)"
      fi
      chmod 644 "$EXCL_H"
    fi
  else
    no "teeth-h: SENTINEL-G: comment not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (i): revert to xargs word-split → space-path block dropped → module uncited → RED
  echo "-- teeth-i: xargs mutant word-splits space subdir; module must go uncited --"
  MUTANT_I="$ROOT/cov-map.MUT-I.sh"
  # SENTINEL-CORPUS-WS: whitespace-safe per-block cat
  if grep -q 'SENTINEL-CORPUS-WS:' "$SUT"; then
    awk '
      /SENTINEL-CORPUS-WS:/ {
        in_b=1
        print "xargs cat < \"$TMP/blocks.txt\" > \"$TMP/corpus.txt\" 2>/dev/null || true"
        next
      }
      in_b && /^# ---------- citation check/ { in_b=0; print; next }
      in_b { next }
      { print }
    ' "$SUT" > "$MUTANT_I"
    SI="$ROOT/si"; CI="$ROOT/ci"
    mk_unit "$SI" "mod_a" "DistinctWidget.java"
    mkdir -p "$CI/sub dir"
    printf 'DistinctWidget.java is referenced here\n' > "$CI/sub dir/proj-bloque1.md"
    rout_i="$(run "$CI" --subject "$SI" 2>/dev/null)"
    mout_i="$(bash "$MUTANT_I" "$CI" --subject "$SI" 2>/dev/null)"
    if printf '%s' "$rout_i" | grep -qE '1/1 cited' \
       && printf '%s' "$mout_i" | grep -qE '0/1 cited'; then
      ok "teeth-i: original cites space-path block (1/1); xargs mutant drops it (0/1) — bites"
    else
      no "teeth-i: whitespace-safe mutation did not change citation" \
         "orig=$(printf '%s' "$rout_i" | grep 'modules:') mut=$(printf '%s' "$mout_i" | grep 'modules:')"
    fi
  else
    no "teeth-i: SENTINEL-CORPUS-WS: not found in SUT (cannot anchor mutation)"
  fi

  # ---- tooth (j): silence WARN printf → unreadable block goes unreported → RED
  echo "-- teeth-j: drop-WARN mutant; unreadable block WARN must disappear --"
  MUTANT_J="$ROOT/cov-map.MUT-J.sh"
  # SENTINEL-CORPUS-WARN: warn on dropped blocks
  if grep -q 'SENTINEL-CORPUS-WARN:' "$SUT"; then
    sed 's/printf .WARN: %d of %d block files.*/: # MUTATED-J/' "$SUT" > "$MUTANT_J"
    SJ="$ROOT/sj"; CJ="$ROOT/cj"
    mk_unit "$SJ" "mod_a" "AppCore.java"
    mk_corpus "$CJ" "proj-bloque1.md" "AppCore.java is here"
    chmod 000 "$CJ/proj-bloque1.md"
    if [ "$(id -u)" -eq 0 ]; then
      ok "teeth-j: skipped (running as root; chmod 000 not effective for root)"
    else
      rout_j="$(bash "$SUT" "$CJ" --subject "$SJ" 2>&1)"
      mout_j="$(bash "$MUTANT_J" "$CJ" --subject "$SJ" 2>&1)"
      if printf '%s' "$rout_j" | grep -q 'WARN:.*block files unreadable' \
         && ! printf '%s' "$mout_j" | grep -q 'WARN:.*block files unreadable'; then
        ok "teeth-j: original WARNs on unreadable block; drop-WARN mutant silences it — bites"
      else
        no "teeth-j: drop-WARN mutant did not change WARN output" \
           "orig_warn=$(printf '%s' "$rout_j" | grep -c 'WARN:') mut_warn=$(printf '%s' "$mout_j" | grep -c 'WARN:')"
      fi
      chmod 644 "$CJ/proj-bloque1.md"
    fi
  else
    no "teeth-j: SENTINEL-CORPUS-WARN: not found in SUT (cannot anchor mutation)"
  fi
fi

# ---------- footer
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
