#!/usr/bin/env bash
# profile-target.test.sh — characterization/regression harness for profile-target.sh,
# the entry-point CLASSIFIER the methodology tells every research agent to trust first.
#
# WHY THIS SHAPE. profile-target.sh is pure string→wrapper routing: its ONLY external
# input is the output of `file -b`, and suggest() maps that description to a suggested
# decompilation wrapper via an ORDERED case. The routing is trivially fakeable, so we
# make the suite fully hermetic by shadowing `file` on PATH with a stub that echoes each
# fixture's OWN CONTENT as the canned `file -b` description — giving byte-exact control of
# the routing input with zero dependence on the host's real magic database. We pin every
# meaningful case arm, the magic-byte fallback interpolation, the associative-array
# aggregation (COUNT keyed on the wrapper's first word), and the exit codes. The teeth
# control neuters the .Net/Mono arm on a throwaway SUT copy and proves a PE32+.NET fixture
# then MISROUTES to native — the exact case-arm-ordering shadow risk FABLE flagged.
#
# The SUT is READ-ONLY and is NEVER modified by this suite.
#
# Usage: profile-target.test.sh                (run the suite)
#        profile-target.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit:  0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../profile-target.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/stage"; STUB="$TMP/stub"; mkdir -p "$STAGE" "$STUB"
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- Hermetic `file` stub -------------------------------------------------
# The SUT calls `file -b "$f"` (unqualified) as its ONLY external routing input.
# The stub echoes the fixture's own content, so the fixture content IS the exact
# `file -b` description the SUT sees — deterministic, offline, host-independent.
cat > "$STUB/file" <<'STUBEOF'
#!/usr/bin/env bash
# canned `file` stub: `file -b <path>` prints the target fixture's own content.
cat "${@: -1}"
STUBEOF
chmod +x "$STUB/file"

# --- Fixtures & helpers ---------------------------------------------------
# mkcase <dirname> <filename> <file-description-content> → echoes the target dir.
# A single-file target dir isolates one case arm per routing assertion.
mkcase() {
  local d="$STAGE/$1"; mkdir -p "$d"
  printf '%s' "$3" > "$d/$2"
  printf '%s' "$d"
}
# route <dir> → echoes the wrapper column (field 3) of the FIRST table row.
# Rows are the only lines containing ' | ' (header/summary/notes have none).
route() {
  local out
  out="$(PATH="$STUB:$PATH" "$BASH_BIN" "$SUT" "$1" 2>&1)" || true
  awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$out"
}
run_full() { PATH="$STUB:$PATH" "$BASH_BIN" "$SUT" "$@" 2>&1; }
rc_of()    { PATH="$STUB:$PATH" "$BASH_BIN" "$SUT" "$@" >/dev/null 2>&1; echo $?; }

# expect_route <label> <dir> <exact-wrapper>
expect_route() {
  local got; got="$(route "$2")"
  if [ "$got" = "$3" ]; then ok "$1" "→ $got"; else no "$1" "got=[$got] want=[$3]"; fi
}
# expect_has <label> <dir> <substring>
expect_has() {
  local got; got="$(route "$2")"
  case "$got" in *"$3"*) ok "$1" "→ $got";; *) no "$1" "got=[$got] want*=[$3]";; esac
}

echo "== profile-target.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# CASE ARMS — one fixture per meaningful suggest() branch.
expect_route "1  Java class          → decompile-java.sh" \
  "$(mkcase c1 App.class 'compiled Java class data, version 52.0')" \
  'decompile-java.sh'

expect_route "2  Java archive        → decompile-java.sh" \
  "$(mkcase c2 lib.jar 'Java archive data (JAR)')" \
  'decompile-java.sh'

# Zip-but-not-Java-archive is a DISTINCT arm (kept below the Java arms).
expect_route "3  Zip archive         → decompile-java.sh (if .jar)" \
  "$(mkcase c3 z.jar 'Zip archive data, at least v1.0 to extract')" \
  'decompile-java.sh (if .jar)'

expect_route "4  .Net assembly       → decompile-net.sh" \
  "$(mkcase c4 a.dll '.Net assembly, for MS Windows')" \
  'decompile-net.sh'

expect_route "5  ELF shared object   → decompile-native.sh" \
  "$(mkcase c5 libx.so 'ELF 64-bit LSB shared object, x86-64, dynamically linked')" \
  'decompile-native.sh'

expect_route "6  ELF executable      → decompile-native.sh" \
  "$(mkcase c6 prog.bin 'ELF 64-bit LSB executable, x86-64, statically linked')" \
  'decompile-native.sh'

expect_route "7  PE32 / MS Windows   → net?/native" \
  "$(mkcase c7 app.exe 'PE32 executable (console) Intel 80386, for MS Windows')" \
  'decompile-net.sh? / decompile-native.sh'

expect_route "8  PDF document        → fetch-doc.sh" \
  "$(mkcase c8 doc.pdf 'PDF document, version 1.7')" \
  'fetch-doc.sh (extract text/OCR)'

expect_has   "9  firmware            → scan-firmware.sh" \
  "$(mkcase c9 fw.fw 'u-boot legacy uImage firmware, ARM')" \
  'scan-firmware.sh'

expect_has   "10 filesystem          → scan-firmware.sh" \
  "$(mkcase c10 sys.img 'Linux rev 1.0 ext4 filesystem data')" \
  'scan-firmware.sh'

# ---------------------------------------------------------------------------
# FALLBACKS — the 'data'/'empty' arm and the catch-all '*)' arm both exist to
# guarantee opaque/proprietary containers are NEVER silently skipped.
#
# P4 NOTE: after the text-like annotation was added (P4), a 'data' fixture whose
# content is purely printable ASCII would score >90% and route to 'text-like' rather
# than 'opaque'. Test 11 must use a binary fixture so it continues to pin the opaque
# path; the text-like path is pinned by test 25 (P4). The fixture is built manually
# (mkcase can't inject binary bytes through a string arg): "data" prefix (4 printable
# bytes) + bytes 1–49 (non-null control chars, all non-printable outside the
# \011\012\015\040-\176 range used by the text-like check → ~13% printable < 90%).
c11dir="$STAGE/c11"; mkdir -p "$c11dir"
python3 -c "import sys; sys.stdout.buffer.write(b'data' + b'\x01' * 50)" \
  > "$c11dir/blob.scfx"
expect_has   "11 generic 'data' (binary) → firmware + MANUAL (opaque, not text-like)" \
  "$c11dir" \
  'scan-firmware.sh + MANUAL (opaque'

expect_has   "12 'empty' string      → firmware + MANUAL (opaque)" \
  "$(mkcase c12 e.scf 'empty')" \
  'scan-firmware.sh + MANUAL (opaque'

# Unknown description matching NO tool arm and lacking the words "data"/"empty"
# → the bare catch-all '*)'. NOTE: the '*"data"*' arm above is greedy — any
# `file` output containing the word "data" (e.g. "PNG image data") lands there,
# so the catch-all is reached only by descriptors WITHOUT it (e.g. keys/fonts).
expect_has   "13 unknown descriptor  → firmware + MANUAL (magic)" \
  "$(mkcase c13 img.rom 'OpenPGP Public Key')" \
  'scan-firmware.sh + MANUAL (magic'

# A genuinely 0-byte fixture → stub yields empty `file` output ("") → catch-all.
expect_has   "14 real empty file     → firmware + MANUAL (magic)" \
  "$(mkcase c14 z.dat '')" \
  'scan-firmware.sh + MANUAL (magic'

# ---------------------------------------------------------------------------
# MAGIC-BYTE FALLBACK INTERPOLATION. The 'data' arm embeds $(magic "$f"), which
# xxd's the REAL first 8 bytes of the file. Feed known bytes and assert the hex
# appears in the wrapper — proving the fallback actually reads the file, not a
# static string. 'dataXXXX' → 64 61 74 61 58 58 58 58.
expect_has   "15 magic bytes embedded in fallback wrapper" \
  "$(mkcase c15 opaque.pak 'dataXXXX')" \
  '6461 7461 5858 5858'

# ---------------------------------------------------------------------------
# CASE-ARM ORDERING (regression lock). A .NET assembly's real `file` output also
# contains "PE32" and "MS Windows". Because the .Net/Mono arm sits ABOVE the PE32
# arm, it wins → decompile-net.sh. If someone reorders PE32 above it, this fixture
# would misroute to net?/native. Assert the EXACT net-only route.
NETPE='PE32 executable (console) Intel 80386 Mono/.Net assembly, for MS Windows'
expect_route "16 PE32+.NET (ordering) → decompile-net.sh (net arm wins over PE32)" \
  "$(mkcase c16 mixed.exe "$NETPE")" \
  'decompile-net.sh'

# ---------------------------------------------------------------------------
# ASSOCIATIVE-ARRAY AGGREGATION. COUNT is keyed on the wrapper's FIRST WORD
# (${w%% *}). Distinct wrappers → distinct keys; variants sharing a first word
# collapse into one key.
# 16a — two ELF + one PDF → native=2, fetch-doc=1 (distinct keys counted).
agg="$STAGE/agg"; mkdir -p "$agg"
printf '%s' 'ELF 64-bit LSB shared object, x86-64'   > "$agg/one.so"
printf '%s' 'ELF 64-bit LSB executable, x86-64'      > "$agg/two.so"
printf '%s' 'PDF document, version 1.5'              > "$agg/doc.pdf"
aout="$(run_full "$agg")"
if grep -Eq 'decompile-native\.sh +2' <<<"$aout" && grep -Eq 'fetch-doc\.sh +1' <<<"$aout"; then
  ok "17 aggregation: distinct wrappers counted (native=2, fetch-doc=1)"
else
  no "17 aggregation: distinct wrappers counted" "out=[$aout]"
fi

# 16b — Java class + Zip-jar share first-word 'decompile-java.sh' → one key = 2.
col="$STAGE/collapse"; mkdir -p "$col"
printf '%s' 'compiled Java class data, version 52.0' > "$col/A.class"
printf '%s' 'Zip archive data, at least v1.0'        > "$col/b.jar"
cout="$(run_full "$col")"
if grep -Eq 'decompile-java\.sh +2' <<<"$cout"; then
  ok "18 aggregation: wrapper variants collapse on first-word key (java=2)"
else
  no "18 aggregation: wrapper variants collapse on first-word key" "out=[$cout]"
fi

# ---------------------------------------------------------------------------
# EXIT CODES & EMPTY-TARGET behaviour.
# 19 — missing arg → usage, exit 2.
[ "$(rc_of)" = 2 ] && ok "19 no target arg → exit 2" || no "19 no target arg → exit 2" "rc=$(rc_of)"

# 20 — nonexistent path → exit 2.
[ "$(rc_of "$TMP/does-not-exist")" = 2 ] \
  && ok "20 nonexistent target → exit 2" \
  || no "20 nonexistent target → exit 2" "rc=$(rc_of "$TMP/does-not-exist")"

# 21 — source-only dir (no allowlisted extensions) → exit 0 + 'source-code target' hint.
src="$STAGE/srconly"; mkdir -p "$src"
printf 'int main(){}' > "$src/main.c"; printf '# readme' > "$src/README.md"
srco="$(run_full "$src")"; srcrc="$(rc_of "$src")"
if [ "$srcrc" = 0 ] && grep -qiE 'no known binaries|source-code target' <<<"$srco"; then
  ok "21 source-only dir → exit 0 + source-code hint"
else
  no "21 source-only dir → exit 0 + source-code hint" "rc=$srcrc out=[$srco]"
fi

# ---------------------------------------------------------------------------
# EXTERNAL-CONTRACT GAPS (failure path + documented CLI/env surface).

# 22 — file(1) FAILURE PATH. The SUT reads `file -b "$f" 2>/dev/null || echo unknown`
# (line 52). When `file` itself ERRORS (non-zero exit), the fallback yields the token
# "unknown", which matches NO tool/data/empty arm → the catch-all '*)' MANUAL route.
# A SECOND failing stub (exit 1, no stdout) drives this. TEETH: the SAME fixture under
# the WORKING stub routes to fetch-doc.sh — so the MANUAL route below is caused by
# file's FAILURE, not the content. (Under `set -e`, dropping the `|| echo unknown`
# fallback would abort the loop mid-assignment and emit NO row — so this row's very
# presence + MANUAL route is what the fallback guarantees.)
STUB_ERR="$TMP/stuberr"; mkdir -p "$STUB_ERR"
cat > "$STUB_ERR/file" <<'ERREOF'
#!/usr/bin/env bash
# canned FAILING `file` stub: always exits non-zero, prints nothing.
exit 1
ERREOF
chmod +x "$STUB_ERR/file"
g1dir="$(mkcase c22 doc.pdf 'PDF document, version 1.7')"
g1_err="$(PATH="$STUB_ERR:$PATH" "$BASH_BIN" "$SUT" "$g1dir" 2>&1)" || true
g1_errroute="$(awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$g1_err")"
g1_ok="$(PATH="$STUB:$PATH" "$BASH_BIN" "$SUT" "$g1dir" 2>&1)" || true
g1_okroute="$(awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$g1_ok")"
g1_manual=0; g1_fetch=0
case "$g1_errroute" in *"scan-firmware.sh + MANUAL (magic"*) g1_manual=1;; esac
case "$g1_okroute"  in *"fetch-doc.sh"*)                      g1_fetch=1;;  esac
if [ "$g1_manual" = 1 ] && [ "$g1_fetch" = 1 ]; then
  ok "22 file(1) errors → 'unknown' → catch-all MANUAL (teeth: working stub → fetch-doc)" "→ $g1_errroute"
else
  no "22 file(1) errors → catch-all MANUAL fallback" "err=[$g1_errroute] ok=[$g1_okroute]"
fi

# 23 — `--max N` TRUNCATION BOUNDARY. With more files than the limit, the loop must
# stop at N rows and print the "... (cut at N; raise with --max)" notice (lines 51),
# still exiting 0. TEETH: the SAME target WITHOUT --max processes ALL files and prints
# NO cut notice — so the single-row cut below is caused by the boundary, not by input.
maxdir="$STAGE/maxcut"; mkdir -p "$maxdir"
printf '%s' 'ELF 64-bit LSB executable, x86-64' > "$maxdir/a.bin"
printf '%s' 'ELF 64-bit LSB executable, x86-64' > "$maxdir/b.bin"
printf '%s' 'ELF 64-bit LSB executable, x86-64' > "$maxdir/c.bin"
cut_out="$(run_full "$maxdir" --max 1)"; cut_rc="$(rc_of "$maxdir" --max 1)"
cut_rows="$(grep -c ' | ' <<<"$cut_out")"
full_out="$(run_full "$maxdir")"
full_rows="$(grep -c ' | ' <<<"$full_out")"
if [ "$cut_rows" -eq 1 ] && grep -qF '... (cut at 1' <<<"$cut_out" && [ "$cut_rc" = 0 ] \
   && [ "$full_rows" -eq 3 ] && ! grep -qF '(cut at' <<<"$full_out"; then
  ok "23 --max N truncates at N rows + cut notice, exit 0 (teeth: no --max → all 3 rows)" "rows=$cut_rows"
else
  no "23 --max N truncation boundary" "cut_rows=$cut_rows rc=$cut_rc full_rows=$full_rows"
fi

# 24 — EXTRA_EXT EXTENDS THE ALLOWLIST. '.wasm' is NOT in BASE_EXT (line 24), so without
# EXTRA_EXT the SUT never scans it (n=0 → 'no known binaries' hint). With EXTRA_EXT="wasm"
# the file is found and classified. TEETH: assert BOTH directions — the file is picked up
# ONLY when EXTRA_EXT names its extension.
extdir="$STAGE/extraext"; mkdir -p "$extdir"
printf '%s' 'ELF 64-bit LSB executable, x86-64' > "$extdir/mod.wasm"
with_out="$(PATH="$STUB:$PATH" EXTRA_EXT="wasm" "$BASH_BIN" "$SUT" "$extdir" 2>&1)" || true
with_route="$(awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$with_out")"
without_out="$(PATH="$STUB:$PATH" EXTRA_EXT="" "$BASH_BIN" "$SUT" "$extdir" 2>&1)" || true
without_rows="$(grep -c ' | ' <<<"$without_out")"
g3_native=0
case "$with_route" in *"decompile-native.sh"*) g3_native=1;; esac
if [ "$g3_native" = 1 ] && [ "$without_rows" -eq 0 ] \
   && grep -qiE 'no known binaries|source-code target' <<<"$without_out"; then
  ok "24 EXTRA_EXT adds '.wasm' to allowlist (teeth: unset → skipped, n=0)" "→ $with_route"
else
  no "24 EXTRA_EXT extends allowlist" "with=[$with_route] without_rows=$without_rows"
fi

# ---------------------------------------------------------------------------
# P4 — TEXT-LIKE ANNOTATION. A 'data'-type file whose first 512 bytes are >90%
# printable ASCII (space, tab, LF, CR, and glyphs 0x20–0x7E) should be annotated
# "(text-like — try reading it first)" instead of the opaque label. The negative case
# (binary 'data' file → opaque) is covered by the updated test 11 binary fixture above.
c25dir="$STAGE/c25"; mkdir -p "$c25dir"
# Fixture must be no-newline so the stub (cat of file) does not break the printf
# table row — embedded newlines split the row and make awk miss the wrapper column.
# 500 'a' bytes after "data" → 504 printable bytes, no newlines → ratio 100% > 90%.
python3 -c "import sys; sys.stdout.buffer.write(b'data' + b'a' * 500)" \
  > "$c25dir/textblob.dat"
expect_has   "25 P4: 'data' file >90% printable ASCII → text-like annotation" \
  "$c25dir" \
  'text-like — try reading it first'

# ---------------------------------------------------------------------------
# CAD (DXF / DWG) ROUTING — render-drawing.sh must be suggested for AutoCAD files.
# Both extensions must be in BASE_EXT (discovered by find) AND the AutoCAD case arm
# must route them to render-drawing.sh. ONE arm covers both because the real `file -b`
# output for each contains the token "AutoCAD" (verified against the real fleet CAD
# files in nave-panccadia/raw/). Using one test per extension is mandatory because
# DXF and DWG produce DIFFERENT `file` strings; one positive does not prove the other.
expect_route "26 DXF (AutoCAD Exchange Format) → render-drawing.sh" \
  "$(mkcase c26 drawing.dxf 'AutoCAD Drawing Exchange Format, version 2007')" \
  'render-drawing.sh'

expect_route "27 DWG (DWG AutoDesk AutoCAD) → render-drawing.sh" \
  "$(mkcase c27 drawing.dwg 'DWG AutoDesk AutoCAD 2007/2008/2009')" \
  'render-drawing.sh'

# Aggregation: DXF + DWG share the 'render-drawing.sh' first-word key in COUNT, so
# the summary line must show 'render-drawing.sh 2' when both appear in one target.
cad_agg="$STAGE/cad_agg"; mkdir -p "$cad_agg"
printf '%s' 'AutoCAD Drawing Exchange Format, version 2007' > "$cad_agg/plan.dxf"
printf '%s' 'DWG AutoDesk AutoCAD 2007/2008/2009'          > "$cad_agg/plan.dwg"
cad_out="$(run_full "$cad_agg")"
if grep -Eq 'render-drawing\.sh +2' <<<"$cad_out"; then
  ok "28 aggregation: DXF + DWG → render-drawing.sh COUNT key = 2"
else
  no "28 aggregation: DXF + DWG → render-drawing.sh summary" "out=[$cad_out]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Case 16 claims the .Net/Mono arm sitting ABOVE the
# PE32 arm is what routes a .NET+PE32 file to net-only. Prove it: neuter that arm
# on a throwaway SUT copy (rewrite its pattern to one that can never match) and
# re-run the SAME fixture. The file must now fall through to the PE32 arm and
# MISROUTE to native. If the mutant still routed net-only, case 16 would be theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the .Net/Mono case arm; expect .NET+PE32 fixture to misroute → native --"
  anchor='*".Net assembly"*|*"Mono/.Net"*'
  repl='*"ZZZ_NEVER_MATCH_ZZZ"*'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate .Net/Mono case arm" "anchor not found — SUT drifted?"
  else
    mutant="$TMP/profile-target.MUTANT.sh"
    printf '%s\n' "${content/"$anchor"/"$repl"}" > "$mutant"
    d="$STAGE/teeth"; mkdir -p "$d"
    printf '%s' "$NETPE" > "$d/x.exe"
    mout="$(PATH="$STUB:$PATH" "$BASH_BIN" "$mutant" "$d" 2>&1)"
    mroute="$(awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$mout")"
    case "$mroute" in
      *"decompile-native.sh"*)
        ok "teeth: .Net-arm-neutered mutant misroutes .NET→native (case 16 has teeth)" "($mroute)" ;;
      *)
        no "teeth: mutant did NOT misroute" "got=[$mroute] — case-arm ordering test is THEATER" ;;
    esac
  fi

  # teeth-p4: neuter P4-TEXT-LIKE-ANNOT on a throwaway SUT copy; the all-ASCII
  # 'data' fixture (same as test 25) must STOP emitting the text-like annotation —
  # proving the annotation is load-bearing and test 25 is not theater.
  echo "-- teeth-p4: neuter P4-TEXT-LIKE-ANNOT; ASCII 'data' fixture must NOT show text-like --"
  p4sentinel='# P4-TEXT-LIKE-ANNOT'
  p4content="$(cat "$SUT")"
  if [[ "$p4content" != *"$p4sentinel"* ]]; then
    no "teeth-p4: P4-TEXT-LIKE-ANNOT sentinel not found in SUT (P4 not implemented or marker missing)"
  else
    p4mutant="$TMP/profile-target.P4MUTANT.sh"
    sed '/# P4-TEXT-LIKE-ANNOT/ s/.*/  if false; then  # P4-TEXT-LIKE-ANNOT [NEUTERED]/' \
      "$SUT" > "$p4mutant"
    p4dir_t="$TMP/p4dir"; mkdir -p "$p4dir_t"
    python3 -c "import sys; sys.stdout.buffer.write(b'data' + b'a' * 500)" \
      > "$p4dir_t/textblob.dat"
    p4mout="$(PATH="$STUB:$PATH" "$BASH_BIN" "$p4mutant" "$p4dir_t" 2>&1)"
    if ! grep -q 'text-like' <<<"$p4mout"; then
      ok "teeth-p4: neutered annotation → ASCII 'data' fixture shows NO text-like (test 25 has teeth)"
    else
      no "teeth-p4: mutant STILL shows text-like → test 25 is THEATER" "p4mout=[$p4mout]"
    fi
  fi

  # teeth-autocad: neuter the AutoCAD case arm on a throwaway SUT copy; the DXF
  # fixture (same description as test 26) must fall through to the catch-all and
  # show 'scan-firmware.sh + MANUAL' instead of 'render-drawing.sh'. Proves tests
  # 26-28 are not theater. bash -n validates the mutant parses before we run it —
  # a mutant with a syntax error cannot run so the control would pass for the wrong reason.
  echo "-- teeth-autocad: neuter AutoCAD case arm; DXF must fall through to catch-all --"
  autocad_anchor='*"AutoCAD"*)'
  autocad_repl='*"ZZZ_NEVER_MATCH_ZZZ"*)'
  autocad_content="$(cat "$SUT")"
  if [[ "$autocad_content" != *"$autocad_anchor"* ]]; then
    no "teeth-autocad: locate AutoCAD case arm" "anchor not found — SUT drifted?"
  else
    autocad_mutant="$TMP/profile-target.AUTOCAD-MUTANT.sh"
    printf '%s\n' "${autocad_content/"$autocad_anchor"/"$autocad_repl"}" > "$autocad_mutant"
    if ! bash -n "$autocad_mutant" >/dev/null 2>&1; then
      no "teeth-autocad: mutant parse check (bash -n)" "mutant has syntax error — teeth are theater"
    else
      teeth_cad_dir="$STAGE/teeth-autocad"; mkdir -p "$teeth_cad_dir"
      printf '%s' 'AutoCAD Drawing Exchange Format, version 2007' > "$teeth_cad_dir/plan.dxf"
      autocad_mout="$(PATH="$STUB:$PATH" "$BASH_BIN" "$autocad_mutant" "$teeth_cad_dir" 2>&1)"
      autocad_mroute="$(awk -F ' [|] ' '/ [|] / { print $3; exit }' <<<"$autocad_mout")"
      case "$autocad_mroute" in
        *"render-drawing.sh"*)
          no "teeth-autocad: mutant still routed to render-drawing.sh (arm neuter had no effect)" ;;
        *"scan-firmware.sh + MANUAL"*)
          ok "teeth-autocad: AutoCAD-arm-neutered mutant falls through to catch-all (tests 26-28 have teeth)" "($autocad_mroute)" ;;
        *)
          no "teeth-autocad: unexpected route on mutant" "got=[$autocad_mroute]" ;;
      esac
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
