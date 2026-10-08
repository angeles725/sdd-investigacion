#!/usr/bin/env bash
# census-target.test.sh — characterization harness for census-target.sh (METHODOLOGY §6,
# BOOTSTRAP step a2). The census is a pure information tool: it walks all files under a dir,
# groups by extension, and stars (*) any type that meets the audit threshold (>=N files or
# >=M MB). This suite pins: (a) exit codes, (b) that starred types appear for threshold-
# crossing inputs, (c) that sub-threshold types are NOT starred, (d) case-insensitive
# extension folding. The mutation tooth inverts the threshold comparison so every type is
# starred regardless of count, then asserts a sub-threshold type is STILL not starred after
# the flag is set — proving the guard is load-bearing.
#
# Usage: census-target.test.sh                (run the suite)
#        census-target.test.sh --prove-teeth  (run suite + mutation tooth)
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../census-target.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
# MUT holds every mutant, OUTSIDE the live tree (kit #943/#1299: a mutant written beside the SUT
# lands in the tracked tree).  The two skip-accounting mutants are mutants of THIS test file, which
# finds the SUT as "$HERE/../census-target.sh"; they therefore live in a mirrored layout —
# "$MUT/tests/<mutant>" next to a verbatim copy "$MUT/census-target.sh" — so $SUT stays reachable.
MUT="$(mktemp -d)"; mkdir -p "$MUT/tests"
trap 'rm -rf "$TMP" "$MUT"' EXIT
pass=0; fail=0; skipped=0
ok()   { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-60s %s\n' "$1" "${2:-}"; skipped=$((skipped+1)); }

# _IS_ROOT: always derived from id -u for ordinary invocations.
# A lone environment variable cannot influence this.
# The --prove-teeth block forces the root path only via TWO combined signals:
#   (1) the explicit internal argument --_teeth-probe-root
#   (2) the namespaced env marker _CENSUS_TEETH_PROBE="census-target.test.sh"
# Neither signal alone is sufficient.  Coverage is a function of the machine,
# not of what happens to be in the environment.
_IS_ROOT=0
[ "$(id -u)" = 0 ] && _IS_ROOT=1
if [ "${1:-}" = "--_teeth-probe-root" ] \
   && [ "${_CENSUS_TEETH_PROBE:-}" = "census-target.test.sh" ]; then
  _IS_ROOT=1
fi

run()  { bash "$SUT" "$@" 2>&1; }
code() { bash "$SUT" "$@" >/dev/null 2>&1; echo $?; }

# --- mutation-control helpers (kit issues #943, #1299) -------------------------------------------
# Mutants are built by lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or
# live-tree mutant; each control then asserts the GOOD verdict on the original AND the SPECIFIC BAD
# verdict on the mutant.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_built >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_built/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
# The builders and the exact-verdict runner are shared (lib/mutant.sh, #1299): they print their own
# FAIL/PASS line and return non-zero on failure; these adapters only COUNT. MK_ORIG overrides the
# original a mutant is built from (default $SUT).
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain "$l" "${MK_ORIG:-$SUT}" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
mk_verify() { mutant_built "$1" "${MK_ORIG:-$SUT}" "$2" || { fail=$((fail+1)); return 1; }; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

echo "== census-target.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — no arg → exit 2 (bad args).
[ "$(code)" = 2 ] && ok "no arg → exit 2" || no "no arg: got $(code) (want 2)"

# 2 — non-directory arg → exit 2.
[ "$(code "$TMP/does-not-exist")" = 2 ] \
  && ok "non-directory arg → exit 2" \
  || no "non-dir: got $(code "$TMP/does-not-exist") (want 2)"

# 3 — empty directory → exit 0.
d="$TMP/empty"; mkdir -p "$d"
[ "$(code "$d")" = 0 ] && ok "empty dir → exit 0" || no "empty dir: exit $(code "$d") (want 0)"

# 4 — valid dir → exit 0.
d="$TMP/valid"; mkdir -p "$d"
printf 'x\n' > "$d/a.txt"
[ "$(code "$d")" = 0 ] && ok "valid dir with files → exit 0" || no "valid: exit $(code "$d") (want 0)"

# 5 — STARRED for threshold-crossing count (>=5 files of same extension).
# Create 5 .pdf files. Default threshold is count=5, so exactly 5 should be starred.
d="$TMP/threshold-count"; mkdir -p "$d"
for i in 1 2 3 4 5; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if grep -qE 'pdf.*\*' <<<"$out"; then
  ok "5 .pdf files → pdf starred (*) at threshold count=5" "(found '*' on pdf line)"
else
  no "5 .pdf files → pdf should be starred" "$(echo "$out" | grep -i pdf || echo '(pdf line absent)')"
fi

# 6 — NOT starred below threshold (4 files < default count=5).
d="$TMP/below-count"; mkdir -p "$d"
for i in 1 2 3 4; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if ! grep -qE 'pdf.*\*' <<<"$out"; then
  ok "4 .pdf files → pdf NOT starred (below threshold)" "(no '*' on pdf line)"
else
  no "4 .pdf files → pdf should NOT be starred" "$(echo "$out" | grep -i pdf | head -1)"
fi

# 7 — STARRED for custom threshold-count override (--threshold-count 3).
d="$TMP/custom-count"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 3)"
if grep -qE 'docx.*\*' <<<"$out"; then
  ok "--threshold-count 3: 3 .docx files → starred" "(threshold override honored)"
else
  no "--threshold-count 3: 3 .docx files should be starred" "$(echo "$out" | grep -i docx || echo '(docx line absent)')"
fi

# 8 — NOT starred when count=3 with threshold=4.
d="$TMP/under-custom"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 4)"
if ! grep -qE 'docx.*\*' <<<"$out"; then
  ok "--threshold-count 4: 3 .docx files → NOT starred (below custom threshold)" "(no '*' on docx)"
else
  no "--threshold-count 4: 3 .docx files should NOT be starred" "$(echo "$out" | grep -i docx | head -1)"
fi

# 9 — Case-insensitive extension folding: .PDF and .pdf counted together.
d="$TMP/case-fold"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/doc${i}.PDF"; done
for i in 4 5;   do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
# 5 files total under the 'pdf' key → must be starred; only ONE pdf line (not PDF + pdf).
pdf_lines="$(echo "$out" | grep -iE '^\s+pdf\s' | wc -l | tr -d ' ')"
if grep -qE 'pdf.*\*' <<<"$out" && [ "$pdf_lines" = "1" ]; then
  ok "case-fold: .PDF + .pdf merged → single pdf line, starred" "(${pdf_lines} pdf line(s))"
else
  no "case-fold: expected 1 starred pdf line" "pdf_lines=$pdf_lines; out=$(echo "$out" | grep -iE 'pdf' | head -2 | tr '\n' '|')"
fi

# 10 — Files WITHOUT extension reported as '(no ext)'.
d="$TMP/no-ext"; mkdir -p "$d"
printf 'x\n' > "$d/Makefile"
printf 'x\n' > "$d/README"
out="$(run "$d")"
if grep -q '(no ext)' <<<"$out"; then
  ok "files without extension → '(no ext)' group" "(no-ext line present)"
else
  no "files without extension: expected '(no ext)' group" "$(echo "$out" | head -5 | tr '\n' '|')"
fi

# 11 — .git directory excluded: git objects must NOT inflate the '(no ext)' count.
# census-target.sh prints a histogram (count/ext/MB) — it NEVER prints filenames.
# Asserting that the filename 'abc123' is absent was pure theater; the real guard is the
# -not -path '*/.git/*' find flag. With the exclusion active, the only no-extension file
# (the .git object) is skipped → '(no ext)' row must be ABSENT. If the exclusion is
# removed the object IS counted and '(no ext)' appears. The prove-teeth tooth confirms this.
d="$TMP/with-git"; mkdir -p "$d/.git/objects"
printf 'x\n' > "$d/.git/objects/abc123"  # no-extension file inside .git — must be excluded
printf 'x\n' > "$d/real.txt"              # .txt extension — appears in histogram, not (no ext)
out="$(run "$d")"
if ! grep -qF '(no ext)' <<<"$out"; then
  ok "11 .git/ excluded: '(no ext)' row absent (only no-ext file is the .git object)" \
     "(git exclusion works)"
else
  no "11 .git/ not excluded: '(no ext)' row present — git object counted in histogram" \
     "$(echo "$out" | grep '(no ext)')"
fi

# ---------------------------------------------------------------------------
# 12 — STARRED via MB threshold: 1 file exactly 1MB (= THRESH_MB_BYTES), count=1 < threshold=5.
# The MB arm must fire independently of the count arm.
d="$TMP/threshold-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/archive.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "12 1 file exactly 1MB → iso starred (*) via MB threshold arm" "(count=1 < 5; MB arm fires)"
else
  no "12 1 file 1MB → iso should be starred via MB arm" \
     "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 13 — NOT starred below both thresholds: 1 tiny file (count < 5, bytes << 1MB).
d="$TMP/below-both"; mkdir -p "$d"
printf 'hello\n' > "$d/tiny.iso"
out="$(run "$d")"
if ! grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "13 1 tiny file → iso NOT starred (below both count and MB thresholds)" "(no '*' on iso)"
else
  no "13 1 tiny file → iso should NOT be starred" \
     "$(echo "$out" | grep -i iso | head -1)"
fi

# 14 — MB boundary: exactly 1MB − 1 byte (1048575 bytes) must NOT be starred via MB arm
# (count=1 < threshold=5, bytes strictly below THRESH_MB_BYTES=1048576).
d="$TMP/below-mb-boundary"; mkdir -p "$d"
dd if=/dev/zero of="$d/almost.bin" bs=1048575 count=1 2>/dev/null
out="$(run "$d")"
if ! grep -qE 'bin[[:space:]].*\*' <<<"$out"; then
  ok "14 1048575 bytes (1MB − 1 B) → NOT starred (strictly below 1MB threshold)" "(boundary below)"
else
  no "14 1048575 bytes: should NOT be starred (below 1MB)" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 15 — Custom --threshold-mb 2: file of exactly 2MB → starred; below 2MB → not starred.
d="$TMP/custom-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/big.bin" bs=1048576 count=2 2>/dev/null   # 2MB exactly
out="$(run "$d" --threshold-mb 2)"
if grep -qE 'bin[[:space:]].*\*' <<<"$out"; then
  ok "15 --threshold-mb 2: exactly 2MB → starred at custom MB threshold" "(MB override honored)"
else
  no "15 --threshold-mb 2: 2MB file should be starred" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 16 — UNREADABLE DIRECTORY must be REPORTED, never silently skipped.
# This is the tool's own founding failure re-entering through the back door: the census exists
# because 681 Access databases were never surfaced, and a `find … 2>/dev/null` cannot tell
# "nothing there" from "could not look". These corpora live on WSL2 /mnt paths with Windows
# ACLs, so unreadable subtrees are the normal case, not the exotic one. The census must print a
# WARNING naming how many paths it could not traverse, so an undercount is visible rather than
# indistinguishable from a clean census.
# Skipped under root, where chmod 000 does not deny traversal.
d="$TMP/unreadable"; mkdir -p "$d/open" "$d/locked"
printf 'x\n' > "$d/open/visible.txt"
printf 'x\n' > "$d/locked/hidden.mdb"
if [ "$_IS_ROOT" = 1 ]; then
  skip "16 unreadable dir warning — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory)"
else
  chmod 000 "$d/locked"
  out="$(run "$d")"; rcu=$?
  chmod 0755 "$d/locked" 2>/dev/null
  if [ "$rcu" = 0 ] && grep -qiE 'WARNING.*(unreadable|could not|permission)' <<<"$out"; then
    ok "16 unreadable subtree → WARNING printed, exit stays 0 (undercount is visible, not silent)"
  else
    no "16 unreadable subtree: exit=$rcu (want 0) / warning=$(grep -ciE 'WARNING.*(unreadable|could not|permission)' <<<"$out") :: $(echo "$out" | tr '\n' '|')"
  fi
fi

# 17 — Paths containing SPACES must be attributed to the right extension and size.
# Pins the size/path parsing contract independently of how sizes are collected, so a switch
# away from the per-file `stat` subprocess cannot silently corrupt the histogram.
d="$TMP/spacey"; mkdir -p "$d/a folder with spaces"
dd if=/dev/zero of="$d/a folder with spaces/big report.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if grep -qE 'iso[[:space:]]+1[[:space:]]+1\.0' <<<"$out" && grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "17 path with spaces → 1 iso file at 1.0 MB, starred (size/path parsing intact)"
else
  no "17 spaces in path: expected 1 iso @ 1.0 MB starred" "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 18 — UNREADABLE DIRECTORY WARNING must appear on STDOUT, not only stderr.
# A researcher who runs `census-target.sh <target> > census.txt` or pastes the captured
# output into RESEARCH-STATE loses the WARNING if it only goes to stderr — the undercount
# becomes invisible at exactly the moment the census is archived and trusted. The fix must
# route the WARNING through stdout so it travels with the report body.
# Skipped under root, where chmod 000 does not deny traversal.
if [ "$_IS_ROOT" = 1 ]; then
  skip "18 WARNING on stdout — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory)"
else
  d="$TMP/unreadable-stdout"; mkdir -p "$d/open" "$d/locked"
  printf 'x\n' > "$d/open/visible.txt"
  printf 'x\n' > "$d/locked/hidden.mdb"
  chmod 000 "$d/locked"
  out="$(bash "$SUT" "$d" 2>/dev/null)"; rco=$?
  chmod 0755 "$d/locked" 2>/dev/null
  if [ "$rco" = 0 ] && grep -qiE 'WARNING.*(unreadable|could not|permission)' <<<"$out"; then
    ok "18 unreadable subtree → WARNING appears on STDOUT (travels with captured report, not orphaned on stderr)"
  else
    no "18 WARNING must appear on stdout (not only stderr): exit=$rco / stdout=$(echo "$out" | tr '\n' '|')"
  fi
fi

# ---------------------------------------------------------------------------
# 19..33 — Audit cross-check (--state <RESEARCH-STATE.md>, kit #965). The audit obligation for
# starred types used to be prose-only; with --state the census cross-checks each starred type
# against the state file's '## Gap-backlog' and '## Dismissed file types' sections (literal-name
# match, WARN-only: exit stays 0). Typed states: OK / WARNING / NO-STARRED / INHERITED /
# DEGRADED (state unreadable, or neither section present) / not run (no --state flag).
# The target has three starred types of DIFFERENT counts so the sorted list has a FIRST (.aaa,
# 7 files), MIDDLE (.bbb, 6) and LAST (.ccc, 5) row; .zzz (1 file) is not starred.
xt="$TMP/xcheck-target"; mkdir -p "$xt"
for i in 1 2 3 4 5 6 7; do printf 'x\n' > "$xt/f${i}.aaa"; done
for i in 1 2 3 4 5 6;   do printf 'x\n' > "$xt/g${i}.bbb"; done
for i in 1 2 3 4 5;     do printf 'x\n' > "$xt/h${i}.ccc"; done
printf 'x\n' > "$xt/one.zzz"
mkst() { # mkst <file> <backlog-body> <dismissed-body|-NOSECTION->
  { printf '# state\n\n## Gap-backlog\n\n%s\n\n## Iteration history\n\nnotes\n' "$2"
    if [ "$3" != "-NOSECTION-" ]; then printf '\n## Dismissed file types\n\n%s\n' "$3"; fi; } > "$1"
}
xrun() { bash "$SUT" "$xt" --state "$1" 2>&1; }
xline() { grep 'Audit cross-check: WARNING' <<<"$1"; }

# 19 — all three starred types named (backlog and dismissed mixed) → OK; unstarred .zzz is not required.
mkst "$TMP/st-ok.md" "| high | G1 Read the .aaa files | x |" "- .bbb — 6 files · 0.0 MB — dismissed: fixtures
- .ccc — 5 files · 0.0 MB — dismissed: fixtures"
out="$(xrun "$TMP/st-ok.md")"
grep -q 'Audit cross-check: OK' <<<"$out" && ! xline "$out" >/dev/null \
  && ok "19 all starred types named → cross-check OK" || no "19 expected OK" "$(grep 'Audit cross-check' <<<"$out")"

# 20..22 — an uncovered type in FIRST / MIDDLE / LAST position is named, the covered ones are not.
mkst "$TMP/st-first.md" "| high | G1 .bbb and .ccc | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-first.md")"
w="$(xline "$out")"
grep -q 'WARNING: 1 of 3 starred type' <<<"$w" && grep -q '\.aaa' <<<"$w" && ! grep -qE '\.(bbb|ccc)' <<<"$w" \
  && ok "20 FIRST starred type (.aaa) uncovered → named" || no "20 first-position hole" "$w"
mkst "$TMP/st-mid.md" "| high | G1 .aaa and .ccc | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-mid.md")"
w="$(xline "$out")"
grep -q 'WARNING: 1 of 3 starred type' <<<"$w" && grep -q '\.bbb' <<<"$w" && ! grep -qE '\.(aaa|ccc)' <<<"$w" \
  && ok "21 MIDDLE starred type (.bbb) uncovered → named" || no "21 middle-position hole" "$w"
mkst "$TMP/st-last.md" "| high | G1 .aaa and .bbb | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-last.md")"
w="$(xline "$out")"
grep -q 'WARNING: 1 of 3 starred type' <<<"$w" && grep -q '\.ccc' <<<"$w" && ! grep -qE '\.(aaa|bbb)' <<<"$w" \
  && ok "22 LAST starred type (.ccc) uncovered → named" || no "22 last-position hole" "$w"

# 23 — WARN-only: a hole never changes the exit code.
mkst "$TMP/st-none.md" "| high | G1 nothing relevant | x |" "- .zzz — dismissed: irrelevant"
bash "$SUT" "$xt" --state "$TMP/st-none.md" >/dev/null 2>&1; rc=$?
out="$(xrun "$TMP/st-none.md")"
[ "$rc" = 0 ] && grep -q 'WARNING: 3 of 3 starred type' <<<"$out" \
  && ok "23 all three uncovered → WARNING 3 of 3, exit 0 (WARN-only)" || no "23 exit/count" "rc=$rc $(grep 'Audit cross-check' <<<"$out")"

# 24 — a mention OUTSIDE the two sections (Blocked gaps) does not close the audit.
mkst "$TMP/st-hist.md" "| high | G1 .aaa and .bbb | x |" "- .zzz — dismissed: irrelevant"
printf '\n## Blocked gaps\n\n.ccc was mentioned here only\n' >> "$TMP/st-hist.md"
out="$(xrun "$TMP/st-hist.md")"
w="$(xline "$out")"
grep -q 'WARNING: 1 of 3' <<<"$w" && grep -q '\.ccc' <<<"$w" \
  && ok "24 mention outside backlog/dismissed sections does not close the audit" || no "24 section scoping" "$w"

# 25 — token boundary + case folding: '.aaax' / 'xaaa' must not claim .aaa; '.BBB' claims .bbb.
mkst "$TMP/st-bound.md" "| high | G1 .aaax xaaa .BBB .ccc | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-bound.md")"
w="$(xline "$out")"
grep -q 'WARNING: 1 of 3' <<<"$w" && grep -q '\.aaa' <<<"$w" && ! grep -qE '\.(bbb|ccc)' <<<"$w" \
  && ok "25 token boundary holds (.aaax / xaaa do not claim .aaa) and match is case-insensitive" || no "25 boundary/case" "$w"

# 26 — absent state file → DEGRADED (typed), never a silent OK.
out="$(xrun "$TMP/no-such-state.md")"; bash "$SUT" "$xt" --state "$TMP/no-such-state.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'Audit cross-check: DEGRADED' <<<"$out" && ! grep -q 'Audit cross-check: OK' <<<"$out" \
  && ok "26 absent state file → DEGRADED, not OK (exit 0)" || no "26 absent state" "rc=$rc $(grep 'Audit cross-check' <<<"$out")"

# 27 — state with NEITHER section → DEGRADED (cannot see any claim).
printf '# state\n\n## Coverage\n\nx\n' > "$TMP/st-nosec.md"
out="$(xrun "$TMP/st-nosec.md")"
grep -q 'Audit cross-check: DEGRADED' <<<"$out" && ! grep -q 'Audit cross-check: OK' <<<"$out" \
  && ok "27 state without Gap-backlog and Dismissed sections → DEGRADED" || no "27 no sections" "$(grep 'Audit cross-check' <<<"$out")"

# 28 — Dismissed section absent but backlog names every starred type → OK with the absence disclosed.
mkst "$TMP/st-nodis.md" "| high | G1 .aaa .bbb .ccc | x |" "-NOSECTION-"
out="$(xrun "$TMP/st-nodis.md")"
grep -q 'Audit cross-check: OK' <<<"$out" && grep -qi 'no .## Dismissed file types. section' <<<"$out" \
  && ok "28 Dismissed section absent, backlog covers all → OK with the absence disclosed" || no "28 no dismissed section" "$(grep -i 'cross-check\|Dismissed' <<<"$out" | head -3)"

# 29 — no starred types → NO-STARRED (distinct from OK).
nt="$TMP/xcheck-nostar"; mkdir -p "$nt"; printf 'x\n' > "$nt/a.txt"
out="$(bash "$SUT" "$nt" --state "$TMP/st-ok.md" 2>&1)"
grep -q 'Audit cross-check: NO-STARRED' <<<"$out" && ! grep -q 'Audit cross-check: OK' <<<"$out" \
  && ok "29 no starred types → NO-STARRED (distinct from OK)" || no "29 no starred" "$(grep 'Audit cross-check' <<<"$out")"

# 30 — '(no ext)' starred: needs the literal '(no ext)' in a section.
ne="$TMP/xcheck-noext"; mkdir -p "$ne"
for i in 1 2 3 4 5; do printf 'x\n' > "$ne/LICENSE${i}"; done
mkst "$TMP/st-ne-bad.md" "| high | G1 ext files | x |" "- .zzz — dismissed: irrelevant"
mkst "$TMP/st-ne-ok.md" "| high | G1 x | x |" "- (no ext) — 5 files · 0.0 MB — dismissed: license texts"
out1="$(bash "$SUT" "$ne" --state "$TMP/st-ne-bad.md" 2>&1)"; out2="$(bash "$SUT" "$ne" --state "$TMP/st-ne-ok.md" 2>&1)"
grep -q 'WARNING: 1 of 1' <<<"$out1" && grep -qF '(no ext)' <<<"$(xline "$out1")" && grep -q 'Audit cross-check: OK' <<<"$out2" \
  && ok "30 (no ext) starred: uncovered → WARNING, '(no ext)' in Dismissed → OK" || no "30 no-ext" "$(grep 'Audit cross-check' <<<"$out1")"

# 31 — declared inherited census (METHODOLOGY §6) → INHERITED, not a silent OK and not a WARNING.
mkst "$TMP/st-inh.md" "| high | G1 x | x |" "- none — census inherited from parent corpus bootstrap (scoped focus; reads subset x already classified)"
out="$(xrun "$TMP/st-inh.md")"
grep -q 'Audit cross-check: INHERITED' <<<"$out" && ! xline "$out" >/dev/null \
  && ok "31 declared inherited census → INHERITED" || no "31 inherited" "$(grep 'Audit cross-check' <<<"$out")"

# 32 — without --state the cross-check is reported as not run (the gap is visible); --state without a value → exit 2.
out="$(run "$xt")"
grep -q 'Audit cross-check: not run' <<<"$out" \
  && ok "32 no --state → 'not run' line (the gap is visible)" || no "32 not-run line" "$(grep 'cross-check' <<<"$out")"
[ "$(code "$xt" --state)" = 2 ] && ok "33 --state without a value → exit 2" || no "33 --state w/o value: got $(code "$xt" --state)"

# 34..45 — Claim hygiene (Opus review of #1984): a claim must be a standalone type token in
# live prose. HTML comments (template text), fenced blocks and filenames-in-prose do not claim;
# types of <= 2 characters need their leading dot; INHERITED is read only from the Dismissed
# section; a heading inside a comment is not a section.
# 34 — a multi-line HTML comment naming .aaa .bbb .ccc (the template-comment shape) claims nothing.
mkst "$TMP/st-cmt.md" "<!-- template: list the file types you read,
     e.g. .aaa .bbb
     and .ccc -->
| high | G1 nothing named | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-cmt.md")"; w="$(xline "$out")"
grep -q 'WARNING: 3 of 3' <<<"$w" \
  && ok "34 multi-line HTML comment naming every type claims nothing" || no "34 comment leak" "$(grep 'Audit cross-check' <<<"$out")"
# 35 — a one-line comment beside a real claim: the claim counts, the comment text does not.
mkst "$TMP/st-cmt1.md" "| high | G1 .aaa .bbb | x | <!-- .ccc -->" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-cmt1.md")"; w="$(xline "$out")"
grep -q 'WARNING: 1 of 3' <<<"$w" && grep -q '\.ccc' <<<"$w" \
  && ok "35 inline HTML comment does not claim; the live claims on the same line still do" || no "35 inline comment" "$w"
# 36 — a fenced block (example text) claims nothing.
mkst "$TMP/st-fence.md" "| high | G1 .aaa .bbb | x |
\`\`\`
- .ccc — 5 files — dismissed: example only
\`\`\`" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-fence.md")"; w="$(xline "$out")"
grep -q 'WARNING: 1 of 3' <<<"$w" && grep -q '\.ccc' <<<"$w" \
  && ok "36 fenced block does not claim" || no "36 fence leak" "$w"
# 37 — filenames in prose are not a type claim: 'notes.aaa', 'RESEARCH-STATE.bbb', 'x.ccc.map'.
mkst "$TMP/st-fname.md" "| high | G1 see notes.aaa and RESEARCH-STATE.bbb and x.ccc.map | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-fname.md")"; w="$(xline "$out")"
grep -q 'WARNING: 3 of 3' <<<"$w" \
  && ok "37 filename-in-prose (notes.aaa, RESEARCH-STATE.bbb, x.ccc.map) claims nothing" || no "37 filename leak" "$w"
# 38 — sentence-final dot still claims ('.aaa.'), a bare 3+-char word claims ('bbb'), and a path segment does not ('dir/ccc').
mkst "$TMP/st-tok.md" "| high | G1 reads the .aaa. Also bbb files; dir/ccc | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-tok.md")"; w="$(xline "$out")"
grep -q 'WARNING: 1 of 3' <<<"$w" && grep -q '\.ccc' <<<"$w" && ! grep -qE '\.(aaa|bbb)' <<<"$w" \
  && ok "38 '.aaa.' and bare 'bbb' claim; path segment 'dir/ccc' does not" || no "38 token forms" "$w"
# 39 — types of <= 2 characters need the leading dot: bare 'c' / 'js' words do not claim .c / .js.
sh2="$TMP/xcheck-short"; mkdir -p "$sh2"
for i in 1 2 3 4 5; do printf 'x\n' > "$sh2/a${i}.c"; printf 'x\n' > "$sh2/b${i}.js"; done
mkst "$TMP/st-short-bad.md" "| high | G1 a c b and js scripts, h | x |" "- .zzz — dismissed: irrelevant"
mkst "$TMP/st-short-ok.md" "| high | G1 .c sources | x |" "- .js — 5 files — dismissed: fixtures"
out1="$(bash "$SUT" "$sh2" --state "$TMP/st-short-bad.md" 2>&1)"; out2="$(bash "$SUT" "$sh2" --state "$TMP/st-short-ok.md" 2>&1)"
w="$(xline "$out1")"
grep -q 'WARNING: 2 of 2' <<<"$w" && grep -q 'Audit cross-check: OK' <<<"$out2" \
  && ok "39 one/two-char types need the leading dot (bare c / js do not claim; .c / .js do)" || no "39 short types" "$w | $(grep 'Audit cross-check' <<<"$out2")"
# 40 — INHERITED only counts inside the Dismissed section, and accepts '--' as well as the em dash.
mkst "$TMP/st-inh-bl.md" "- none — census inherited from parent corpus bootstrap (in the WRONG section)" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-inh-bl.md")"
grep -q 'Audit cross-check: WARNING' <<<"$out" && ! grep -q 'Audit cross-check: INHERITED' <<<"$out" \
  && ok "40 inherited declaration in the Gap-backlog section is NOT honoured" || no "40 inherited scope" "$(grep 'Audit cross-check' <<<"$out")"
mkst "$TMP/st-inh-dd.md" "| high | G1 x | x |" "- none -- census inherited from parent corpus bootstrap (scoped focus)"
out="$(xrun "$TMP/st-inh-dd.md")"
grep -q 'Audit cross-check: INHERITED' <<<"$out" \
  && ok "41 inherited declaration with '--' instead of an em dash → INHERITED" || no "41 inherited --" "$(grep 'Audit cross-check' <<<"$out")"
# 42 — headings inside a comment are not sections: comment-only 'sections' → DEGRADED, not a silent OK.
printf '# state\n\n<!--\n## Gap-backlog\n## Dismissed file types\n- .aaa .bbb .ccc\n-->\n\n## Coverage\n\nx\n' > "$TMP/st-cmthead.md"
out="$(xrun "$TMP/st-cmthead.md")"
grep -q 'Audit cross-check: DEGRADED' <<<"$out" && ! grep -q 'Audit cross-check: OK' <<<"$out" \
  && ok "42 headings inside an HTML comment are not sections → DEGRADED" || no "42 comment headings" "$(grep 'Audit cross-check' <<<"$out")"
# 43 — the OK line carries the literal-name caveat.
out="$(xrun "$TMP/st-ok.md")"
grep -qE 'Audit cross-check: OK.*by literal name' <<<"$out" \
  && ok "43 OK line states it is by literal name" || no "43 OK caveat" "$(grep 'Audit cross-check' <<<"$out")"
# 44 — --state "" → exit 2 (an empty path is a usage error, not 'not run').
[ "$(code "$xt" --state "")" = 2 ] && ok "44 --state '' → exit 2" || no "44 --state '': got $(code "$xt" --state "")"
# 45 — absent state is typed 'absent'; a directory is typed 'not readable' (two different states).
out1="$(xrun "$TMP/no-such-state.md")"; mkdir -p "$TMP/state-is-dir"; out2="$(xrun "$TMP/state-is-dir")"
grep -q 'DEGRADED — state file absent' <<<"$out1" && ! grep -q 'not readable' <<<"$out1" \
  && grep -q 'DEGRADED — state file not readable' <<<"$out2" && ! grep -q 'absent' <<<"$out2" \
  && ok "45 absent state file vs directory/unreadable are distinct DEGRADED states" || no "45 absent vs unreadable" "$(grep 'cross-check' <<<"$out1") | $(grep 'cross-check' <<<"$out2")"
# 46 — trailing boundary: '.aaa.map' (a compound filename) does not claim .aaa.
mkst "$TMP/st-trail.md" "| high | G1 bundles/app.bbb .ccc and then .aaa.map | x |" "- .zzz — dismissed: irrelevant"
out="$(xrun "$TMP/st-trail.md")"; w="$(xline "$out")"
grep -q 'WARNING: 2 of 3' <<<"$w" && grep -q '\.aaa' <<<"$w" && grep -q '\.bbb' <<<"$w" && ! grep -q '\.ccc' <<<"$w" \
  && ok "46 compound '.aaa.map' and 'app.bbb' claim nothing; standalone .ccc does" || no "46 trailing boundary" "$w"

# ---------------------------------------------------------------------------
# TEETH: mutate the awk threshold comparison to make EVERY type starred, then assert a
# sub-threshold type (1 file, well below count=5) is STILL not starred on the original SUT.
# The mutant (flag=1 always) MUST star the sub-threshold type — proving the comparison
# in the SUT is the load-bearing guard, not decoration.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force flag=1 in awk; sub-threshold type must be starred in mutant but not in SUT --"
  d="$TMP/teeth-dir"; mkdir -p "$d"
  printf 'x\n' > "$d/onlyone.xyz"   # 1 file — well below threshold=5

  # Original: exit 0 and the 1-file type is NOT starred. Mutant (flag always "*"): exit 0 and it IS.
  mutant="$MUT/census-target.MUTANT.sh"
  # Swap the conditional expression in the awk to always set flag="*"
  mk_sed "teeth" "$mutant" 's/flag = (cnt\[e\] >= tc + 0 || bytes\[e\] >= tm + 0) ? "\*" : ""/flag = "*"/' \
    && tooth "teeth: mutant (flag=1 always) stars the sub-threshold type; SUT does not (guard is load-bearing)" 0 0 "$mutant" \
         --good-lacks 'xyz.*\*' --bad-has 'xyz.*\*' -- bash @SUT@ "$d"

  # ---------------------------------------------------------------------------
  # SKIP-ACCOUNTING TEETH
  # Cases 16 and 18 emit skip() (not ok()) when chmod 000 does not deny
  # traversal, because the fixture cannot produce the locked-directory
  # condition under test.  The teeth prove:
  #   (a) the skip sites emit SKIP lines, not PASS lines;
  #   (b) the pass counter is untouched by each skip call;
  #   (c) re-routing either site back through ok() turns the control RED.
  #
  # Forcing mechanism: TWO combined signals are required — the explicit
  # internal argument --_teeth-probe-root AND the namespaced env marker
  # _CENSUS_TEETH_PROBE="census-target.test.sh".  A lone env variable
  # (_IS_ROOT=1 or any single marker) cannot trigger forcing.
  #
  # Root-only branch coverage: neither skip site can be entered in this run
  # (we are not root), so the accounting comes from the forced probe
  # sub-invocations below.  What remains unverified: that an actual root
  # process produces the same accounting — unobservable without being root.
  # The probe sub-invocation is the closest verifiable proxy.
  echo "-- skip-accounting: cases 16 and 18 must land in skipped, not pass --"

  # cnt_occ: count non-overlapping literal occurrences of needle in file.
  # Self-proved below with 0/1/2-on-one-line cases before any use.
  cnt_occ() {
    awk -v n="$1" \
      'BEGIN{c=0}{s=$0;while((p=index(s,n))>0){c++;s=substr(s,p+length(n))}}END{print c}' \
      "$2"
  }
  printf 'no match\n'                              > "$TMP/cnt-proof-skip.txt"
  _cp0="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  printf 'SKIPX16 once\n'                          > "$TMP/cnt-proof-skip.txt"
  _cp1="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  printf 'SKIPX16 and SKIPX16 same line\n'         > "$TMP/cnt-proof-skip.txt"
  _cp2="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  [ "$_cp0" = 0 ] && [ "$_cp1" = 1 ] && [ "$_cp2" = 2 ] \
    && ok "cnt_occ (skip teeth): 0/1/2 same-line → 0/1/2 (self-proof)" \
    || no "cnt_occ (skip teeth): proof failed (0=$_cp0 1=$_cp1 2=$_cp2)"

  # Anchor cardinality: each skip site must appear exactly once in this file.
  # Two techniques prevent self-reference:
  #   (1) Split-variable construction: _a16+_bskip form the anchor at runtime;
  #       neither half alone is the full anchor, so neither assignment line
  #       contains it, and the cnt_occ call stores "${_a16}${_bskip}" as text
  #       (unexpanded) — not the literal concatenation.
  #   (2) Backreference sed: mutation lines use \( \) before the quote, inserting
  #       a backslash that changes the byte sequence at that position so cnt_occ
  #       cannot match those lines against the anchor.
  #   Result: the anchor appears exactly once in the file — at the actual call.
  _self="$HERE/census-target.test.sh"
  _a16='skip "16 unreadable dir warning'
  _a18='skip "18 WARNING on stdout'
  _bskip=' — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory'

  _anc16="$(cnt_occ "${_a16}${_bskip}" "$_self")"
  if [ "$_anc16" = 1 ]; then
    ok "anchor-16: skip site for case 16 occurs exactly once in test file"
  else
    no "anchor-16: occurs $_anc16 time(s) in test file (expected 1); mutation will target wrong site"
  fi

  _anc18="$(cnt_occ "${_a18}${_bskip}" "$_self")"
  if [ "$_anc18" = 1 ]; then
    ok "anchor-18: skip site for case 18 occurs exactly once in test file"
  else
    no "anchor-18: occurs $_anc18 time(s) in test file (expected 1); mutation will target wrong site"
  fi

  # Non-root baseline: fresh sub-invocation so _norm_pass is not polluted by
  # teeth passes in this run's $pass counter.  Extract the full triple
  # (passed, skipped, failed) so all isolation controls can compare it.
  _norm_out="$(bash "$_self" 2>&1)"
  _norm_pass="$(printf '%s\n' "$_norm_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _norm_skip_cnt="$(printf '%s\n' "$_norm_out" | grep -cE '^  SKIP  ')"
  _norm_fail="$(printf '%s\n' "$_norm_out" | awk '/^== [0-9]+ passed/{print $5}')"

  # Env-isolation control: _IS_ROOT=1 in an ordinary invocation must not
  # change the coverage triple.  The comparison is triple-to-triple, not
  # triple-to-zero: on a root machine id -u legitimately produces non-zero
  # skips in the baseline, and demanding _env_skip=0 would false-fail there
  # while reporting "coverage changed" over an unchanged result.
  echo "-- env-isolation: _IS_ROOT=1 alone must not change coverage triple --"
  _env_out="$(_IS_ROOT=1 bash "$_self" 2>&1)"
  _env_pass="$(printf '%s\n' "$_env_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _env_skip="$(printf '%s\n' "$_env_out" | grep -cE '^  SKIP  ')"
  _env_fail="$(printf '%s\n' "$_env_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ -n "$_norm_pass" ] \
     && [ "$_env_pass" = "$_norm_pass" ] \
     && [ "$_env_skip" = "$_norm_skip_cnt" ] \
     && [ "$_env_fail" = "$_norm_fail" ]; then
    ok "env-isolation: _IS_ROOT=1 in env → pass=$_env_pass skip=$_env_skip fail=$_env_fail (triple unchanged; baseline=$_norm_pass/$_norm_skip_cnt/$_norm_fail)"
  else
    no "env-isolation: _IS_ROOT=1 changed coverage — pass=${_env_pass:-?}/${_norm_pass:-?} skip=$_env_skip/${_norm_skip_cnt:-?} fail=${_env_fail:-?}/${_norm_fail:-?}"
  fi

  # Arg-alone control: --_teeth-probe-root WITHOUT _CENSUS_TEETH_PROBE must
  # not activate forcing.  This tests the argument half of the two-signal
  # requirement in isolation — a control that can catch someone dropping the
  # marker check while the env-isolation control stays green.
  echo "-- arg-alone: --_teeth-probe-root without _CENSUS_TEETH_PROBE must not activate forcing --"
  _argonly_out="$(bash "$_self" --_teeth-probe-root 2>&1)"
  _argonly_pass="$(printf '%s\n' "$_argonly_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _argonly_skip="$(printf '%s\n' "$_argonly_out" | grep -cE '^  SKIP  ')"
  _argonly_fail="$(printf '%s\n' "$_argonly_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ -n "$_norm_pass" ] \
     && [ "$_argonly_pass" = "$_norm_pass" ] \
     && [ "$_argonly_skip" = "$_norm_skip_cnt" ] \
     && [ "$_argonly_fail" = "$_norm_fail" ]; then
    ok "arg-alone: --_teeth-probe-root alone → pass=$_argonly_pass skip=$_argonly_skip fail=$_argonly_fail (triple unchanged; baseline=$_norm_pass/$_norm_skip_cnt/$_norm_fail)"
  else
    no "arg-alone: --_teeth-probe-root alone changed coverage — pass=${_argonly_pass:-?}/${_norm_pass:-?} skip=$_argonly_skip/${_norm_skip_cnt:-?} fail=${_argonly_fail:-?}/${_norm_fail:-?}"
  fi

  # Forced-probe sub-invocation: both signals combined (arg + namespaced marker)
  # → cases 16 and 18 take the skip branch.  No --prove-teeth: prevents recursion.
  _root_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_self" --_teeth-probe-root 2>&1)"

  # Case 16 accounting (measured separately from case 18).
  _skip16="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  16 ')"
  _pass16="$(printf '%s\n' "$_root_out" | grep -cE '^  PASS  16 ')"
  if [ "$_skip16" = 1 ] && [ "$_pass16" = 0 ]; then
    ok "skip-acct-16 (GREEN): forced-probe → SKIP line present (1), PASS line absent (0)"
  else
    no "skip-acct-16 (GREEN): skip=$_skip16 (want 1) pass=$_pass16 (want 0)"
  fi

  # Case 18 accounting (measured separately; not inferred from case 16 result).
  _skip18="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  18 ')"
  _pass18="$(printf '%s\n' "$_root_out" | grep -cE '^  PASS  18 ')"
  if [ "$_skip18" = 1 ] && [ "$_pass18" = 0 ]; then
    ok "skip-acct-18 (GREEN): forced-probe → SKIP line present (1), PASS line absent (0)"
  else
    no "skip-acct-18 (GREEN): skip=$_skip18 (want 1) pass=$_pass18 (want 0)"
  fi

  # Summary pass count: the probe converts to SKIP only the sites the baseline
  # did not already skip, so the expected PASS delta is derived from observed
  # skip counts, not fixed at 2 — non-root baseline runs 16 and 18 as PASS so
  # delta is 2; under root both are already skipped so delta is 0.  fail must be 0.
  # Summary format: "== N passed · M failed ==" — $2=N, $4=·, $5=M.
  _root_pass="$(printf '%s\n' "$_root_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _root_fail="$(printf '%s\n' "$_root_out" | awk '/^== [0-9]+ passed/{print $5}')"
  _probe_skip_cnt="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  ')"
  _exp_delta=$(( _probe_skip_cnt - _norm_skip_cnt ))
  if [ -n "$_root_pass" ] && [ -n "$_norm_pass" ] \
     && [ "$_root_pass" = $((_norm_pass - _exp_delta)) ] && [ "$_root_fail" = 0 ]; then
    ok "skip-summary: probe pass=$_root_pass = baseline pass=$_norm_pass − $_exp_delta; fail=$_root_fail (delta derived: probe skips=$_probe_skip_cnt, baseline skips=$_norm_skip_cnt)"
  else
    no "skip-summary: probe pass=${_root_pass:-?} (want $(( ${_norm_pass:-0} - _exp_delta ))) baseline=${_norm_pass:-?} delta=$_exp_delta probe-skips=$_probe_skip_cnt baseline-skips=$_norm_skip_cnt fail=${_root_fail:-?} (want 0)"
  fi

  # Env-isolation-nonzero: the forced-probe baseline has skip≠0 (cases 16 and
  # 18).  Adding _IS_ROOT=1 to the environment of an already-forced invocation
  # must not alter that triple.  This proves the triple comparison holds for
  # a non-zero skip baseline — which the ordinary-baseline control cannot
  # exercise on non-root machines (its baseline has 0 skips there).
  echo "-- env-isolation-nonzero: _IS_ROOT=1 must not change the forced-probe triple (skip≠0 baseline) --"
  _probe_skip="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  ')"
  _probe_env_out="$(_IS_ROOT=1 _CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_self" --_teeth-probe-root 2>&1)"
  _probe_env_pass="$(printf '%s\n' "$_probe_env_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _probe_env_skip="$(printf '%s\n' "$_probe_env_out" | grep -cE '^  SKIP  ')"
  _probe_env_fail="$(printf '%s\n' "$_probe_env_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ "$_probe_env_pass" = "$_root_pass" ] \
     && [ "$_probe_env_skip" = "$_probe_skip" ] \
     && [ "$_probe_env_fail" = "$_root_fail" ]; then
    ok "env-isolation-nonzero: forced-probe+_IS_ROOT=1 → pass=$_probe_env_pass skip=$_probe_env_skip fail=$_probe_env_fail (triple unchanged; baseline=$_root_pass/$_probe_skip/$_root_fail, skip≠0)"
  else
    no "env-isolation-nonzero: env changed forced-probe triple — baseline=${_root_pass}/${_probe_skip}/${_root_fail} env=${_probe_env_pass:-?}/${_probe_env_skip:-?}/${_probe_env_fail:-?}"
  fi

  # Mutation RED check: re-route case 16 skip → ok; forced-probe must show PASS
  # line for case 16, not SKIP, and the pass summary increases by 1.
  # Mutants live in the mirrored $MUT/tests layout so dirname "$0" resolves a SUT copy — no _TEETH_HERE.
  # Backreference \( \) inserts a backslash-paren before the quote, making the
  # sed line's byte sequence differ from the anchor so cnt_occ does not count it.
  # The mutants are mutants of the TEST FILE: built in the mirrored layout under $MUT (see top).
  cp "$SUT" "$MUT/census-target.sh"
  mkdir -p "$MUT/tests/lib" && cp "$HERE/lib/mutant.sh" "$MUT/tests/lib/mutant.sh"   # the mutant test sources it too
  _mut16="$MUT/tests/census-target.SKIPMUT16.sh"
  if MK_ORIG="$_self" mk_sed "skip-mut-16" "$_mut16" \
    's/skip \("16 unreadable dir warning — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/'; then
    _mut16_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_mut16" --_teeth-probe-root 2>&1)"
    _mut16_skip16="$(printf '%s\n' "$_mut16_out" | grep -cE '^  SKIP  16 ')"
    _mut16_pass16="$(printf '%s\n' "$_mut16_out" | grep -cE '^  PASS  16 ')"
    _mut16_sumpass="$(printf '%s\n' "$_mut16_out" | awk '/^== [0-9]+ passed/{print $2}')"
    if [ "$_mut16_pass16" = 1 ] && [ "$_mut16_skip16" = 0 ] \
       && [ -n "$_mut16_sumpass" ] && [ "$_mut16_sumpass" = $((_root_pass + 1)) ]; then
      ok "skip-mut-16 (RED): mutant routes case-16 through ok — PASS present, SKIP absent, pass=$_mut16_sumpass (was $_root_pass)"
    else
      no "skip-mut-16 (RED): expected pass16=1 skip16=0 sumpass=$((_root_pass+1)); got pass16=$_mut16_pass16 skip16=$_mut16_skip16 sum=${_mut16_sumpass:-?}"
    fi
  fi

  # Mutation RED check: re-route case 18 skip → ok; same accounting proof.
  _mut18="$MUT/tests/census-target.SKIPMUT18.sh"
  if MK_ORIG="$_self" mk_sed "skip-mut-18" "$_mut18" \
    's/skip \("18 WARNING on stdout — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/'; then
    _mut18_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_mut18" --_teeth-probe-root 2>&1)"
    _mut18_skip18="$(printf '%s\n' "$_mut18_out" | grep -cE '^  SKIP  18 ')"
    _mut18_pass18="$(printf '%s\n' "$_mut18_out" | grep -cE '^  PASS  18 ')"
    _mut18_sumpass="$(printf '%s\n' "$_mut18_out" | awk '/^== [0-9]+ passed/{print $2}')"
    if [ "$_mut18_pass18" = 1 ] && [ "$_mut18_skip18" = 0 ] \
       && [ -n "$_mut18_sumpass" ] && [ "$_mut18_sumpass" = $((_root_pass + 1)) ]; then
      ok "skip-mut-18 (RED): mutant routes case-18 through ok — PASS present, SKIP absent, pass=$_mut18_sumpass (was $_root_pass)"
    else
      no "skip-mut-18 (RED): expected pass18=1 skip18=0 sumpass=$((_root_pass+1)); got pass18=$_mut18_pass18 skip18=$_mut18_skip18 sum=${_mut18_sumpass:-?}"
    fi
  fi

  echo "-- teeth-git: remove .git exclusion; (no ext) row must appear for the git object --"
  d_git="$TMP/teeth-git-dir"; mkdir -p "$d_git/.git/objects"
  printf 'x\n' > "$d_git/.git/objects/noext"  # no-extension file inside .git
  printf 'x\n' > "$d_git/real.txt"             # .txt extension — unrelated to (no ext)

  # Original: exit 0 and no (no ext) row (the .git object is excluded). Mutant (exclusion removed):
  # exit 0 and the (no ext) row appears.
  git_anchor="-not -path '*/.git/*' "
  sut_git_content="$(cat "$SUT")"
  if [[ "$sut_git_content" != *"$git_anchor"* ]]; then
    no "teeth-git: .git exclusion anchor not found in SUT — SUT drifted?"
  else
    mutant_git="$MUT/census-target.GIT-MUTANT.sh"
    printf '%s\n' "${sut_git_content/"$git_anchor"/}" > "$mutant_git"
    chmod +x "$mutant_git"
    mk_verify "teeth-git" "$mutant_git" \
      && tooth "teeth-git: mutant (no .git exclusion) shows (no ext) row; SUT does not — exclusion is load-bearing (case 11 has teeth)" 0 0 "$mutant_git" \
           --good-lacks '\(no ext\)' --bad-has '\(no ext\)' -- bash @SUT@ "$d_git"
  fi

  echo "-- teeth-mb: neuter byte comparison; 1MB file must NOT be starred in the mutant --"
  d="$TMP/teeth-mb-dir"; mkdir -p "$d"
  dd if=/dev/zero of="$d/onebig.iso" bs=1048576 count=1 2>/dev/null  # 1MB, count=1 < 5

  # Original: exit 0 and the 1MB file IS starred via the MB arm. Mutant (byte comparison neutered,
  # count arm intact): exit 0 and it is NOT starred.
  mutant_mb="$MUT/census-target.MB-MUTANT.sh"
  mk_sed "teeth-mb" "$mutant_mb" 's/bytes\[e\] >= tm + 0/0 >= tm + 0/' \
    && tooth "teeth-mb: byte-neutered mutant does NOT star the 1MB file (count < 5, byte arm dead); SUT does — byte comparison is load-bearing" 0 0 "$mutant_mb" \
         --good-has 'iso[[:space:]].*\*' --bad-lacks 'iso[[:space:]].*\*' -- bash @SUT@ "$d"

  # Audit cross-check teeth (#965): each mutant disables one load-bearing rule of the cross-check;
  # the SUT must show the verdict, the mutant the opposite (exact-verdict, not just "differs").
  echo "-- teeth-xcheck: hole detection / section scoping / token boundary / typed states --"
  mutant_hole="$MUT/census-target.XHOLE-MUTANT.sh"
  mk_sed "teeth-xcheck-hole" "$mutant_hole" 's/\[ "\$_nholes" -gt 0 \]/[ "$_nholes" -gt 99 ]/' \
    && tooth "teeth-xcheck-hole: hole-count gate neutered → mutant says OK for 3 unclosed types; SUT warns" 0 0 "$mutant_hole" \
         --good-has 'Audit cross-check: WARNING: 3 of 3' --bad-lacks 'Audit cross-check: WARNING' -- bash @SUT@ "$xt" --state "$TMP/st-none.md"
  mutant_scope="$MUT/census-target.XSCOPE-MUTANT.sh"
  mk_sed "teeth-xcheck-scope" "$mutant_scope" 's/p = (\$0 ~ \/\^##\[\[:space:\]\]+(Gap-backlog|Dismissed file types)\/)/p = 1/' \
    && tooth "teeth-xcheck-scope: every section counted as a claim → mutant lets a Blocked-gaps mention close .ccc; SUT does not" 0 0 "$mutant_scope" \
         --good-has 'WARNING: 1 of 3' --bad-lacks 'WARNING: 1 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-hist.md"
  mutant_unread="$MUT/census-target.XUNREAD-MUTANT.sh"
  mk_sed "teeth-xcheck-unread" "$mutant_unread" 's/if \[ ! -f "\$STATE" \] || \[ ! -r "\$STATE" \]; then/if false; then/' \
    && tooth "teeth-xcheck-unread: unreadable-state probe removed → mutant loses the 'not readable' diagnosis; SUT names it" 0 0 "$mutant_unread" \
         --good-has 'state file not readable' --bad-lacks 'state file not readable' -- bash @SUT@ "$xt" --state "$TMP/state-is-dir"
  mutant_absent="$MUT/census-target.XABSENT-MUTANT.sh"
  mk_sed "teeth-xcheck-absent" "$mutant_absent" 's/if \[ ! -e "\$STATE" \]; then/if false; then/' \
    && tooth "teeth-xcheck-absent: absent-state probe removed → mutant mislabels it 'not readable'; SUT says 'absent'" 0 0 "$mutant_absent" \
         --good-has 'state file absent' --bad-lacks 'state file absent' -- bash @SUT@ "$xt" --state "$TMP/no-such-state.md"
  mutant_emptyarg="$MUT/census-target.XEMPTYARG-MUTANT.sh"
  mk_sed "teeth-xcheck-emptyarg" "$mutant_emptyarg" 's/ || \[ -z "\$2" \]//' \
    && tooth "teeth-xcheck-emptyarg: empty-path guard removed → mutant exits 0 on --state ''; SUT exits 2" 2 0 "$mutant_emptyarg" \
         -- bash @SUT@ "$xt" --state ""
  mutant_cmt="$MUT/census-target.XCMT-MUTANT.sh"
  mk_sed "teeth-xcheck-comment" "$mutant_cmt" 's/line = substr(line, i + 4); inc = 1/line = substr(line, i + 4); inc = 0/' \
    && tooth "teeth-xcheck-comment: comment stripping neutered → template-comment text claims every type; SUT keeps the 3 holes" 0 0 "$mutant_cmt" \
         --good-has 'WARNING: 3 of 3' --bad-lacks 'WARNING: 3 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-cmt.md" \
    && tooth "teeth-xcheck-comment-heading: comment stripping neutered → headings inside a comment read as sections (no DEGRADED); SUT is DEGRADED" 0 0 "$mutant_cmt" \
         --good-has 'Audit cross-check: DEGRADED' --bad-lacks 'Audit cross-check: DEGRADED' -- bash @SUT@ "$xt" --state "$TMP/st-cmthead.md"
  mutant_fence="$MUT/census-target.XFENCE-MUTANT.sh"
  mk_sed "teeth-xcheck-fence" "$mutant_fence" 's/fence = !fence; next/fence = fence; next/' \
    && tooth "teeth-xcheck-fence: fence tracking neutered → example text in a fenced block claims .ccc; SUT does not" 0 0 "$mutant_fence" \
         --good-has 'WARNING: 1 of 3' --bad-lacks 'WARNING: 1 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-fence.md"
  mutant_lead="$MUT/census-target.XLEAD-MUTANT.sh"
  mk_sed "teeth-xcheck-lead" "$mutant_lead" "s/^_lead=.*/_lead='(^|.)'/" \
    && tooth "teeth-xcheck-lead: leading boundary dropped → 'xaaa' claims .aaa; SUT does not" 0 0 "$mutant_lead" \
         --good-has 'WARNING: 1 of 3' --bad-lacks 'WARNING: 1 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-bound.md"
  mutant_leaddot="$MUT/census-target.XLEADDOT-MUTANT.sh"
  mk_sed "teeth-xcheck-leaddot" "$mutant_leaddot" 's/^_lead=.*/_lead='"'"'(^|[^[:alnum:]_\/-])'"'"'/' \
    && tooth "teeth-xcheck-leaddot: '.' dropped from the leading class → 'RESEARCH-STATE.bbb' claims bare bbb; SUT does not" 0 0 "$mutant_leaddot" \
         --good-has 'WARNING: 3 of 3' --bad-lacks 'WARNING: 3 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-fname.md"
  mutant_trail="$MUT/census-target.XTRAIL-MUTANT.sh"
  mk_sed "teeth-xcheck-trail" "$mutant_trail" "s/^_trail=.*/_trail='(.|\$)'/" \
    && tooth "teeth-xcheck-trail: trailing boundary dropped → '.aaa.map' claims .aaa; SUT does not" 0 0 "$mutant_trail" \
         --good-has 'WARNING: 2 of 3' --bad-lacks 'WARNING: 2 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-trail.md"
  mutant_short="$MUT/census-target.XSHORT-MUTANT.sh"
  mk_sed "teeth-xcheck-short" "$mutant_short" 's/-le 2 \]; then _dot/-le 0 ]; then _dot/' \
    && tooth "teeth-xcheck-short: leading-dot rule for 1-2 char types dropped → bare 'c' / 'js' claim; SUT does not" 0 0 "$mutant_short" \
         --good-has 'WARNING: 2 of 2' --bad-lacks 'WARNING: 2 of 2' -- bash @SUT@ "$sh2" --state "$TMP/st-short-bad.md"
  mutant_case="$MUT/census-target.XCASE-MUTANT.sh"
  mk_sed "teeth-xcheck-case" "$mutant_case" 's/grep -qiE -- "\${_lead}/grep -qE -- "${_lead}/' \
    && tooth "teeth-xcheck-case: case folding dropped → '.BBB' no longer claims .bbb; SUT folds case" 0 0 "$mutant_case" \
         --good-has 'WARNING: 1 of 3' --bad-lacks 'WARNING: 1 of 3' -- bash @SUT@ "$xt" --state "$TMP/st-bound.md"
  mutant_noext="$MUT/census-target.XNOEXT-MUTANT.sh"
  mk_sed "teeth-xcheck-noext" "$mutant_noext" 's/grep -qiF -- "(no ext)" <<<"\$_claims" && continue/false \&\& continue/' \
    && tooth "teeth-xcheck-noext: '(no ext)' claim lookup removed → mutant warns although (no ext) is dismissed; SUT says OK" 0 0 "$mutant_noext" \
         --good-has 'Audit cross-check: OK' --bad-lacks 'Audit cross-check: OK' -- bash @SUT@ "$ne" --state "$TMP/st-ne-ok.md"
  mutant_inh="$MUT/census-target.XINH-MUTANT.sh"
  mk_sed "teeth-xcheck-inherited" "$mutant_inh" 's/census inherited\x27 <<<"\$_dismissed"/census inheritedZ\x27 <<<"$_dismissed"/' \
    && tooth "teeth-xcheck-inherited: inherited-census recognition broken → mutant no longer says INHERITED; SUT does" 0 0 "$mutant_inh" \
         --good-has 'Audit cross-check: INHERITED' --bad-lacks 'Audit cross-check: INHERITED' -- bash @SUT@ "$xt" --state "$TMP/st-inh.md"
  mutant_inhscope="$MUT/census-target.XINHSCOPE-MUTANT.sh"
  mk_sed "teeth-xcheck-inhscope" "$mutant_inhscope" 's/census inherited\x27 <<<"\$_dismissed"/census inherited\x27 <<<"$_claims"/' \
    && tooth "teeth-xcheck-inhscope: inherited read from the whole claim text → a backlog line fakes INHERITED; SUT honours only Dismissed" 0 0 "$mutant_inhscope" \
         --good-has 'Audit cross-check: WARNING' --bad-lacks 'Audit cross-check: WARNING' -- bash @SUT@ "$xt" --state "$TMP/st-inh-bl.md"
  mutant_inhdd="$MUT/census-target.XINHDD-MUTANT.sh"
  mk_sed "teeth-xcheck-inhdd" "$mutant_inhdd" 's/(—|--)\[\[:space:\]\]+census/(—)[[:space:]]+census/' \
    && tooth "teeth-xcheck-inhdd: '--' form dropped → mutant misses the ASCII inherited declaration; SUT accepts it" 0 0 "$mutant_inhdd" \
         --good-has 'Audit cross-check: INHERITED' --bad-lacks 'Audit cross-check: INHERITED' -- bash @SUT@ "$xt" --state "$TMP/st-inh-dd.md"
  mutant_nosec="$MUT/census-target.XNOSEC-MUTANT.sh"
  mk_sed "teeth-xcheck-nosec" "$mutant_nosec" 's/if \[ "\$_has_backlog" = no \] && \[ "\$_has_dismissed" = no \]; then/if false; then/' \
    && tooth "teeth-xcheck-nosec: neither-section probe removed → mutant reports a verdict from a state with no claim sections; SUT is DEGRADED" 0 0 "$mutant_nosec" \
         --good-has 'Audit cross-check: DEGRADED' --bad-lacks 'Audit cross-check: DEGRADED' -- bash @SUT@ "$xt" --state "$TMP/st-nosec.md"
  mutant_okcav="$MUT/census-target.XOKCAV-MUTANT.sh"
  mk_sed "teeth-xcheck-okcaveat" "$mutant_okcav" 's/ (by literal name; a type named in a gap that does not cover it still reads OK)//' \
    && tooth "teeth-xcheck-okcaveat: OK-line caveat removed → mutant's OK no longer says 'by literal name'; SUT does" 0 0 "$mutant_okcav" \
         --good-has 'by literal name' --bad-lacks 'by literal name' -- bash @SUT@ "$xt" --state "$TMP/st-ok.md"
  mutant_nostar="$MUT/census-target.XNOSTAR-MUTANT.sh"
  mk_sed "teeth-xcheck-nostar" "$mutant_nostar" 's/if \[ -z "\$_stars" \]; then/if false; then/' \
    && tooth "teeth-xcheck-nostar: empty-starred branch removed → mutant no longer says NO-STARRED; SUT does" 0 0 "$mutant_nostar" \
         --good-has 'Audit cross-check: NO-STARRED' --bad-lacks 'Audit cross-check: NO-STARRED' -- bash @SUT@ "$nt" --state "$TMP/st-ok.md"
  mutant_nostate="$MUT/census-target.XNOSTATE-MUTANT.sh"
  mk_sed "teeth-xcheck-nostate" "$mutant_nostate" 's/if \[ -z "\$STATE" \]; then/if false; then/' \
    && tooth "teeth-xcheck-nostate: not-run branch removed → mutant emits no 'not run' line; SUT does" 0 0 "$mutant_nostate" \
         --good-has 'Audit cross-check: not run' --bad-lacks 'Audit cross-check: not run' -- bash @SUT@ "$xt"

  # Neutral-mutant refusals (#1299): the helper must reject a mutant that cannot be a real mutation,
  # so a control built from one can never read as teeth. Asserts the SPECIFIC refusal code of each.
  echo "-- teeth-helper: lib/mutant.sh refuses byte-identical / syntax-broken mutants; no-op stage refused --"
  mutant_sed "$SUT" "$MUT/neutral-identical.sh" 's/ZZZ_NO_SUCH_TOKEN_ZZZ/x/' 2>/dev/null; _hrc=$?
  [ "$_hrc" = 4 ] && [ ! -e "$MUT/neutral-identical.sh" ] \
    && ok "teeth-helper: byte-identical (no-op sed) mutant REFUSED with rc=4 and removed" \
    || no "teeth-helper: byte-identical mutant not refused as rc=4" "(rc=$_hrc)"
  mutant_sed "$SUT" "$MUT/neutral-syntax.sh" 's/^set -uo pipefail$/fi/' 2>/dev/null; _hrc=$?
  [ "$_hrc" = 5 ] && [ ! -e "$MUT/neutral-syntax.sh" ] \
    && ok "teeth-helper: syntax-broken mutant REFUSED with rc=5 and removed" \
    || no "teeth-helper: syntax-broken mutant not refused as rc=5" "(rc=$_hrc)"
  _hfail0="$fail"
  mk_sed "chain" "$MUT/neutral-chain.sh" 's/flag = (cnt/flag = (CNT/' 's/ZZZ_NO_SUCH_TOKEN_ZZZ/x/' >/dev/null; _hrc=$?
  _hfail1="$fail"; fail="$_hfail0"   # the refusal was the expected outcome: do not count its no() as a failure
  [ "$_hrc" != 0 ] && [ "$_hfail1" = $((_hfail0 + 1)) ] && [ ! -e "$MUT/neutral-chain.sh" ] \
    && ok "teeth-helper: chain containing a no-op stage REFUSED (no mutant written)" \
    || no "teeth-helper: chain with a no-op stage was not refused" "(rc=$_hrc)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
