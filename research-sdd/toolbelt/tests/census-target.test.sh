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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

run()  { bash "$SUT" "$@" 2>&1; }
code() { bash "$SUT" "$@" >/dev/null 2>&1; echo $?; }

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
if echo "$out" | grep -qE 'pdf.*\*'; then
  ok "5 .pdf files → pdf starred (*) at threshold count=5" "(found '*' on pdf line)"
else
  no "5 .pdf files → pdf should be starred" "$(echo "$out" | grep -i pdf || echo '(pdf line absent)')"
fi

# 6 — NOT starred below threshold (4 files < default count=5).
d="$TMP/below-count"; mkdir -p "$d"
for i in 1 2 3 4; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if ! echo "$out" | grep -qE 'pdf.*\*'; then
  ok "4 .pdf files → pdf NOT starred (below threshold)" "(no '*' on pdf line)"
else
  no "4 .pdf files → pdf should NOT be starred" "$(echo "$out" | grep -i pdf | head -1)"
fi

# 7 — STARRED for custom threshold-count override (--threshold-count 3).
d="$TMP/custom-count"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 3)"
if echo "$out" | grep -qE 'docx.*\*'; then
  ok "--threshold-count 3: 3 .docx files → starred" "(threshold override honored)"
else
  no "--threshold-count 3: 3 .docx files should be starred" "$(echo "$out" | grep -i docx || echo '(docx line absent)')"
fi

# 8 — NOT starred when count=3 with threshold=4.
d="$TMP/under-custom"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 4)"
if ! echo "$out" | grep -qE 'docx.*\*'; then
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
if echo "$out" | grep -qE 'pdf.*\*' && [ "$pdf_lines" = "1" ]; then
  ok "case-fold: .PDF + .pdf merged → single pdf line, starred" "(${pdf_lines} pdf line(s))"
else
  no "case-fold: expected 1 starred pdf line" "pdf_lines=$pdf_lines; out=$(echo "$out" | grep -iE 'pdf' | head -2 | tr '\n' '|')"
fi

# 10 — Files WITHOUT extension reported as '(no ext)'.
d="$TMP/no-ext"; mkdir -p "$d"
printf 'x\n' > "$d/Makefile"
printf 'x\n' > "$d/README"
out="$(run "$d")"
if echo "$out" | grep -q '(no ext)'; then
  ok "files without extension → '(no ext)' group" "(no-ext line present)"
else
  no "files without extension: expected '(no ext)' group" "$(echo "$out" | head -5 | tr '\n' '|')"
fi

# 11 — .git directory excluded: git object files must not appear.
d="$TMP/with-git"; mkdir -p "$d/.git/objects"
printf 'x\n' > "$d/.git/objects/abc123"  # git internal file
printf 'x\n' > "$d/real.txt"
out="$(run "$d")"
# Objects dir should be excluded; '(no ext)' count should be 0 or only count real.txt
if ! echo "$out" | grep -q 'abc123'; then
  ok ".git/ directory excluded from census" "(git object not in output)"
else
  no ".git/ not excluded: git file appeared in output"
fi

# ---------------------------------------------------------------------------
# 12 — STARRED via MB threshold: 1 file exactly 1MB (= THRESH_MB_BYTES), count=1 < threshold=5.
# The MB arm must fire independently of the count arm.
d="$TMP/threshold-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/archive.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
  ok "12 1 file exactly 1MB → iso starred (*) via MB threshold arm" "(count=1 < 5; MB arm fires)"
else
  no "12 1 file 1MB → iso should be starred via MB arm" \
     "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 13 — NOT starred below both thresholds: 1 tiny file (count < 5, bytes << 1MB).
d="$TMP/below-both"; mkdir -p "$d"
printf 'hello\n' > "$d/tiny.iso"
out="$(run "$d")"
if ! echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
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
if ! echo "$out" | grep -qE 'bin[[:space:]].*\*'; then
  ok "14 1048575 bytes (1MB − 1 B) → NOT starred (strictly below 1MB threshold)" "(boundary below)"
else
  no "14 1048575 bytes: should NOT be starred (below 1MB)" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 15 — Custom --threshold-mb 2: file of exactly 2MB → starred; below 2MB → not starred.
d="$TMP/custom-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/big.bin" bs=1048576 count=2 2>/dev/null   # 2MB exactly
out="$(run "$d" --threshold-mb 2)"
if echo "$out" | grep -qE 'bin[[:space:]].*\*'; then
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
if [ "$(id -u)" = 0 ]; then
  ok "16 unreadable dir warning — SKIPPED (running as root; chmod 000 does not deny traversal)"
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
if echo "$out" | grep -qE 'iso[[:space:]]+1[[:space:]]+1\.0' && echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
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
if [ "$(id -u)" = 0 ]; then
  ok "18 WARNING on stdout — SKIPPED (running as root; chmod 000 does not deny traversal)"
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
# TEETH: mutate the awk threshold comparison to make EVERY type starred, then assert a
# sub-threshold type (1 file, well below count=5) is STILL not starred on the original SUT.
# The mutant (flag=1 always) MUST star the sub-threshold type — proving the comparison
# in the SUT is the load-bearing guard, not decoration.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force flag=1 in awk; sub-threshold type must be starred in mutant but not in SUT --"
  d="$TMP/teeth-dir"; mkdir -p "$d"
  printf 'x\n' > "$d/onlyone.xyz"   # 1 file — well below threshold=5

  # First, assert the SUT does NOT star it (negative control).
  out_sut="$(run "$d")"
  if echo "$out_sut" | grep -qE 'xyz.*\*'; then
    no "teeth pre-check: SUT incorrectly stars a 1-file type (baseline broken)" "(can't prove teeth)"
  else
    ok "teeth pre-check: SUT does NOT star 1-file type below threshold" "(baseline clean)"
    # Now build a mutant that forces flag=1 always in awk.
    mutant="$TMP/census-target.MUTANT.sh"
    # Swap the conditional expression in the awk to always set flag="*"
    sed 's/flag = (cnt\[e\] >= tc + 0 || bytes\[e\] >= tm + 0) ? "\*" : ""/flag = "*"/' "$SUT" > "$mutant"
    chmod +x "$mutant"
    out_mut="$(bash "$mutant" "$d" 2>&1)"
    if echo "$out_mut" | grep -qE 'xyz.*\*'; then
      ok "teeth: mutant (flag=1 always) DOES star the sub-threshold type (guard is load-bearing)" "(case 6 has teeth)"
    else
      no "teeth: mutant should star sub-threshold type but did not — guard may not be the decider" \
         "$(echo "$out_mut" | grep -i xyz | head -1)"
    fi
  fi

  echo "-- teeth-mb: neuter byte comparison; 1MB file must NOT be starred in the mutant --"
  d="$TMP/teeth-mb-dir"; mkdir -p "$d"
  dd if=/dev/zero of="$d/onebig.iso" bs=1048576 count=1 2>/dev/null  # 1MB, count=1 < 5

  # Positive control: SUT must star it via MB arm.
  out_sut_mb="$(run "$d")"
  if echo "$out_sut_mb" | grep -qE 'iso[[:space:]].*\*'; then
    ok "teeth-mb pre-check: SUT stars 1MB single file via MB arm" "(positive control)"
    # Mutant: neuter ONLY the byte comparison (0>=tm is always false; count arm still works).
    mutant_mb="$TMP/census-target.MB-MUTANT.sh"
    sed 's/bytes\[e\] >= tm + 0/0 >= tm + 0/' "$SUT" > "$mutant_mb"
    chmod +x "$mutant_mb"
    out_mut_mb="$(bash "$mutant_mb" "$d" 2>&1)"
    if ! echo "$out_mut_mb" | grep -qE 'iso[[:space:]].*\*'; then
      ok "teeth-mb: byte-neutered mutant does NOT star 1MB file (count < 5, byte arm dead) — byte comparison is load-bearing"
    else
      no "teeth-mb: byte-neutered mutant still stars iso — byte comparison may not be the decider (THEATER)" \
         "$(echo "$out_mut_mb" | grep -i iso | head -1)"
    fi
  else
    no "teeth-mb pre-check: SUT fails to star 1MB file (baseline broken, can't prove MB teeth)" \
       "$(echo "$out_sut_mb" | grep -i iso | head -1)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
