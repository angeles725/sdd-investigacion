#!/usr/bin/env bash
# verify-sources.test.sh — RED-FIRST regression harness for verify-sources.sh.
#
# WHY THIS SHAPE (anti-"test theater"): an AI-written test suite drifts toward
# always-green — it exercises only happy paths, or freezes current (buggy) behavior
# as "correct". Such a suite passes on a BROKEN linter too, so it proves nothing.
# This harness is built RED-FIRST: the discriminating cases feed a KNOWN-BAD corpus
# and assert the linter CATCHES it (exit 1), not that a clean corpus passes.
#
# TEETH PROOF (negative control): `--prove-teeth` mutates verify-sources.sh to revert
# its corpus-root resolution (the PR that fixed the subdir false-PASS) and re-runs the
# flagship subdir fixture against the MUTANT, asserting the mutant now FALSE-PASSES
# (exit 0). If the mutant still caught it, the test would not depend on the code under
# test — i.e. it would be theater. A test you have never seen fail is not a test.
#
# Usage: verify-sources.test.sh            (run the suite)
#        verify-sources.test.sh --prove-teeth   (run suite + the mutation negative control)
# Exit: 0 = all assertions held · 1 = a regression (some assertion failed).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-sources.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# assert_exit <script> <expected-code> <label> <target-dir>
assert_exit() {
  local sut="$1" want="$2" label="$3" dir="$4" got
  bash "$sut" "$dir" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-42s (exit %s)\n' "$label" "$got"; pass=$((pass+1))
  else
    printf '  FAIL  %-42s expected exit %s, got %s\n' "$label" "$want" "$got"; fail=$((fail+1))
  fi
}

# --- fixture helpers -------------------------------------------------------
# block <path> <body...> : write a corpus block file
block() { local p="$1"; shift; mkdir -p "$(dirname "$p")"; printf '%s\n' "$@" > "$p"; }
# sources_registry <corpus-dir> <row...> : write a valid SOURCES.md with the given data rows
sources_registry() {
  local dir="$1"; shift; mkdir -p "$dir/sources"
  { printf '# External sources preserved\n\n'
    printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
    printf '|---|---|---|---|---|---|\n'
    for r in "$@"; do printf '%s\n' "$r"; done
  } > "$dir/sources/SOURCES.md"
}

echo "== verify-sources.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# GOOD 1 — flat corpus, only local [CERT] claims, no preserved-source markers → PASS (0)
d="$TMP/good-flat"; mkdir -p "$d"
block "$d/g-block1.md" '# Block 1' '## 1.1 [CERT] file.c:10 — a local claim, no external source.'
assert_exit "$SUT" 0 "GOOD flat corpus (no preserved markers)" "$d"

# GOOD 2 — nested corpus (blocks in corpus/), fully registered → PASS (0)
#          (proves resolution FINDS corpus/ and a clean nested corpus passes)
d="$TMP/good-subdir"; mkdir -p "$d/corpus/sources"
block "$d/corpus/gs-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — cites a preserved datasheet.'
: > "$d/corpus/sources/ds.pdf"
sources_registry "$d/corpus" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 0 "GOOD nested corpus (corpus/, registered)" "$d"

# ---------------------------------------------------------------------------
# BAD 1 — [CERT-doc] cited but NO SOURCES.md (LEVEL 1) → CATCH (1)   [RED-FIRST]
d="$TMP/bad-missing-registry"; mkdir -p "$d/sources"
block "$d/b-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — preserved marker, no registry.'
: > "$d/sources/ds.pdf"
assert_exit "$SUT" 1 "BAD: preserved marker, no SOURCES.md" "$d"

# BAD 2 — a cited sources/ file is absent on disk (LEVEL 3) → CATCH (1)
d="$TMP/bad-cited-missing"; mkdir -p "$d/sources"
block "$d/b-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 and also sources/ghost.pdf §2.'
: > "$d/sources/ds.pdf"   # ds.pdf exists, ghost.pdf does NOT
sources_registry "$d" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 1 "BAD: cited sources/ file absent on disk" "$d"

# BAD 3 — fabricated citation: SOURCES says B5 cites ds.pdf, block5 never mentions it (LEVEL 4) → CATCH (1)
d="$TMP/bad-fabricated"; mkdir -p "$d/sources"
block "$d/b-block5.md" '# Block 5' '## 5.1 [CERT] file.c:1 — this block never references the datasheet.'
: > "$d/sources/ds.pdf"
sources_registry "$d" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 | B5 |'
assert_exit "$SUT" 1 "BAD: fabricated registry->block citation" "$d"

# ---------------------------------------------------------------------------
# FLAGSHIP — nested corpus with a real violation, root empty of blocks.
#   Fixed script resolves corpus/ and CATCHES it (1); the pre-fix script scanned the
#   empty root and FALSE-PASSED (0). This is the exact PR-#6 regression guard.
d="$TMP/flagship-subdir"; mkdir -p "$d/corpus/sources"
block "$d/corpus/fs-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — preserved marker, NO registry.'
: > "$d/corpus/sources/ds.pdf"   # no SOURCES.md in corpus/sources → LEVEL 1 must fire
assert_exit "$SUT" 1 "FLAGSHIP: nested violation caught (not false-passed)" "$d"

# DECOY — root HAS the real (violating) corpus + a clean notes/ decoy that must NOT hijack.
#   Tests the root-preference + deterministic resolution (the niagara notes/ case).
d="$TMP/decoy-root-wins"; mkdir -p "$d/sources" "$d/notes"
block "$d/dr-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — preserved marker, NO registry.'
: > "$d/sources/ds.pdf"
block "$d/notes/decoy-block1.md" '# Notes' '## 1.1 [CERT] scratch.c:1 — clean decoy, no preserved markers.'
assert_exit "$SUT" 1 "DECOY: root wins over notes/ decoy" "$d"

# ---------------------------------------------------------------------------
# LEVEL 5 — web-snapshot integrity. snapshot() writes a raw fetched-content file
# (no provenance header — origin/date/sha256 live ONLY in SOURCES.md).
snapshot() { local p="$1"; shift; mkdir -p "$(dirname "$p")"; printf '%s\n' "$@" > "$p"; }

# BAD 4 — orphan snapshot: foo.md on disk but NOT named in SOURCES.md (LEVEL 5) → CATCH (1)
d="$TMP/bad-orphan-snapshot"; mkdir -p "$d"
block "$d/o-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>raw fetched body, no provenance header</div>'
sources_registry "$d"   # registry exists but does NOT name foo.md
assert_exit "$SUT" 1 "BAD: orphan snapshot (unregistered on disk)" "$d"
# Capture to a var first: under `pipefail`, `SUT | grep` would inherit the SUT's exit 1 even when grep matches.
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'orphan-snapshot' \
  && { printf '  PASS  %-42s (line present)\n' "orphan-snapshot line printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (line missing)\n' "orphan-snapshot line printed"; fail=$((fail+1)); }

# GOOD 3 — registered AND cited by a block → no orphan, PASS (0)
d="$TMP/good-snapshot-cited"; mkdir -p "$d"
block "$d/sc-block1.md" '# Block 1' '## 1.1 [CERT-web] sources/web-snapshots/foo.md — cites the snapshot.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>raw body</div>'
sources_registry "$d" '| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 0 "GOOD snapshot registered + cited" "$d"

# WARN 1 — registered but NO block references it → uncited-snapshot WARN, exit unaffected (0)
d="$TMP/warn-snapshot-uncited"; mkdir -p "$d"
block "$d/wu-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim, does not cite the snapshot.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>raw body</div>'
sources_registry "$d" '| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | abcd123 |  |'
assert_exit "$SUT" 0 "WARN snapshot registered but uncited (exit 0)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'uncited-snapshot' \
  && { printf '  PASS  %-42s (WARN line present)\n' "uncited-snapshot line printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN line missing)\n' "uncited-snapshot line printed"; fail=$((fail+1)); }

# BAD 5 — snapshots on disk but NO SOURCES.md at all → every snapshot is an orphan (LEVEL 5) → CATCH (1)
#   Deliberately NO [CERT-doc]/[CERT-a] markers, so LEVEL 1 stays silent and LEVEL 5 is the failing level.
d="$TMP/bad-snapshot-no-registry"; mkdir -p "$d"
block "$d/nr-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim, no preserved markers.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>raw body, provenance now unrecoverable</div>'
assert_exit "$SUT" 1 "BAD: snapshots on disk, no SOURCES.md" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'orphan-snapshot' \
  && { printf '  PASS  %-42s (LEVEL 5 is the failing level)\n' "no-registry → orphan-snapshot line"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (LEVEL 5 did NOT fire)\n' "no-registry → orphan-snapshot line"; fail=$((fail+1)); }

# GOOD 4 — normal corpus, NO web-snapshots/ dir → PASS (0), no snapshot output
d="$TMP/good-no-snapshot-dir"; mkdir -p "$d"
block "$d/ns-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
assert_exit "$SUT" 0 "GOOD no web-snapshots/ dir" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'web-snapshots:' \
  && { printf '  FAIL  %-42s (summary line leaked)\n' "no dir → no snapshot output"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no snapshot output)\n' "no dir → no snapshot output"; pass=$((pass+1)); }

# GOOD 5 — web-snapshots/ exists but is EMPTY → PASS (0), no snapshot output
d="$TMP/good-empty-snapshot-dir"; mkdir -p "$d/sources/web-snapshots"
block "$d/es-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
assert_exit "$SUT" 0 "GOOD empty web-snapshots/ dir" "$d"

# BAD 6 — SUBSTRING-COLLISION orphan (CRITICAL false-negative guard). A real orphan `report.md` on disk must
#   NOT false-pass just because the registry names `annual-report.md` (which CONTAINS "report.md"). The old
#   basename-substring check passed this; the exact File-column match must CATCH it (1) and name report.md.
d="$TMP/bad-substring-collision"; mkdir -p "$d"
block "$d/cc-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/annual-report.md — the registered one.'
snapshot "$d/sources/web-snapshots/report.md" '<div>orphan — provenance lost</div>'
snapshot "$d/sources/web-snapshots/annual-report.md" '<div>registered + cited</div>'
sources_registry "$d" '| web-snapshots/annual-report.md | web-snapshot | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 1 "BAD: substring-collision orphan (report.md)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'orphan-snapshot: sources/web-snapshots/report.md' \
  && { printf '  PASS  %-42s (names report.md, not annual-report.md)\n' "collision orphan named exactly"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (exact orphan line missing)\n' "collision orphan named exactly"; fail=$((fail+1)); }

# GOOD 6 — NESTED subdir snapshot, correctly cited by full relpath → PASS (0), NO uncited-snapshot.
#   (Old basename logic false-flagged this: base=page.md ≠ the cited nested path.)
d="$TMP/good-nested-snapshot"; mkdir -p "$d"
block "$d/nn-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/example.com/page.md — nested path.'
snapshot "$d/sources/web-snapshots/example.com/page.md" '<div>nested body</div>'
sources_registry "$d" '| web-snapshots/example.com/page.md | web-snapshot | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 0 "GOOD nested snapshot cited by full path" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'uncited-snapshot' \
  && { printf '  FAIL  %-42s (nested cite falsely flagged)\n' "nested snapshot not false-flagged"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no false uncited)\n' "nested snapshot not false-flagged"; pass=$((pass+1)); }

# GOOD 7 — CORRECT elided citation → NO warn. File `foo-KELVIN-Chil.md`, block cites `web-snapshots/...Chil.md`;
#   tail `Chil.md` IS a suffix of the real name → counts as cited (elision-tolerant).
d="$TMP/good-elided-cite"; mkdir -p "$d"
block "$d/ge-block1.md" '# Block 1' '## 1.1 see `sources/web-snapshots/...Chil.md` (elided display path).'
snapshot "$d/sources/web-snapshots/foo-KELVIN-Chil.md" '<div>mib body</div>'
sources_registry "$d" '| web-snapshots/foo-KELVIN-Chil.md | web-snapshot | http://x | 2026-01-01 | abcd123 |  |'
assert_exit "$SUT" 0 "GOOD correct elided citation (no warn)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'uncited-snapshot' \
  && { printf '  FAIL  %-42s (correct elided cite warned)\n' "elided cite counted as cited"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no false uncited)\n' "elided cite counted as cited"; pass=$((pass+1)); }

# WARN 2 — DRIFTED elided citation → uncited-snapshot WARN, exit 0. Block cites `web-snapshots/...Wrong-Name.md`
#   whose tail is NOT a suffix of the real file → genuine name-drift, must still warn (the hifref case).
d="$TMP/warn-drifted-elided"; mkdir -p "$d"
block "$d/wd-block1.md" '# Block 1' '## 1.1 see `sources/web-snapshots/...Wrong-Name.md` (drifted name).'
snapshot "$d/sources/web-snapshots/foo-KELVIN-Chil.md" '<div>mib body</div>'
sources_registry "$d" '| web-snapshots/foo-KELVIN-Chil.md | web-snapshot | http://x | 2026-01-01 | abcd123 |  |'
assert_exit "$SUT" 0 "WARN drifted elided citation (exit 0)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'uncited-snapshot' \
  && { printf '  PASS  %-42s (genuine name-drift kept)\n' "drifted elided still warns"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (drift not caught)\n' "drifted elided still warns"; fail=$((fail+1)); }

# GOOD 8 (FIX A) — TAB-padded File cell must NOT false-orphan a registered snapshot. The registration is a
#   fail-closed, archive-blocking HARD gate; a hand-edited `|\tweb-snapshots/foo.md\t|` cell would false-orphan
#   under space+backtick-only normalization → exit 1 → blocked archive. Tabs are now trimmed from both sides.
#   (Empty Citing-blocks column keeps LEVEL 4 out of it, isolating LEVEL 5 as the level under test.)
d="$TMP/good-tab-padded-registration"; mkdir -p "$d"
block "$d/tp-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — the registered one.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>body</div>'
sources_registry "$d" "$(printf '|\tweb-snapshots/foo.md\t| web-snapshot | http://x | 2026-01-01 | abcd123 |  |')"
assert_exit "$SUT" 0 "GOOD tab-padded File cell (registered)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'orphan-snapshot' \
  && { printf '  FAIL  %-42s (tab padding false-orphaned)\n' "tab-padded cell not false-orphaned"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no false orphan)\n' "tab-padded cell not false-orphaned"; pass=$((pass+1)); }

# WARN 3 (FIX B) — a DEGENERATE elided tail must NOT mask a genuinely-uncited snapshot corpus-wide. A stray
#   `web-snapshots/...md` yields tail `md` which would end-match every *.md; the too-generic tail is REJECTED
#   (needs `<name>.<ext>` with non-empty name), so the uncited WARN for `totally-unrelated.md` still fires.
d="$TMP/warn-degenerate-tail-no-mask"; mkdir -p "$d"
block "$d/dt-block1.md" '# Block 1' '## 1.1 stray mention `sources/web-snapshots/...md` — degenerate, no real name.'
snapshot "$d/sources/web-snapshots/totally-unrelated.md" '<div>uncited body</div>'
sources_registry "$d" '| web-snapshots/totally-unrelated.md | web-snapshot | http://x | 2026-01-01 | abcd123 |  |'
assert_exit "$SUT" 0 "WARN degenerate tail does not mask (exit 0)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'uncited-snapshot' \
  && { printf '  PASS  %-42s (degenerate tail rejected)\n' "degenerate tail did not mask uncited"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (uncited WARN masked)\n' "degenerate tail did not mask uncited"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL — prove the FLAGSHIP test has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth proof: mutate corpus-root resolution, expect the flagship to FALSE-PASS --"
  mutant="$TMP/verify-sources.MUTANT.sh"
  # revert the resolution: force corpus=$target (the pre-fix behavior)
  awk '{ if ($0 ~ /corpus="\$\(dirname "\$anchor"\)"/) print "  corpus=\"$target\"  # MUTANT: resolution reverted"; else print }' "$SUT" > "$mutant"
  if ! grep -q 'MUTANT: resolution reverted' "$mutant"; then
    echo "  FAIL  could not build mutant (resolution line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/flagship-subdir"   # reuse the flagship fixture
    # The MUTANT must FALSE-PASS (exit 0) where the real SUT catches (exit 1).
    bash "$mutant" "$d" >/dev/null 2>&1; mgot=$?
    if [ "$mgot" = 0 ]; then
      printf '  PASS  %-42s (mutant false-passes → real test has teeth)\n' "teeth: mutant exit 0, SUT exit 1"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 0). Flagship does NOT depend on the resolution — THEATER.\n' "teeth" "$mgot"; fail=$((fail+1))
    fi
  fi

  # LEVEL 5 teeth: revert the registration to the OLD basename-substring check and assert the substring-
  #   collision orphan (BAD 6) then FALSE-PASSES — proving the exact File-column match is load-bearing.
  echo "-- teeth proof: revert LEVEL 5 to basename-substring, expect the collision orphan to FALSE-PASS --"
  mutant5="$TMP/verify-sources.MUTANT5.sh"
  awk '{ if ($0 ~ /grep -qxF "\$rel"/) print "  if ! grep -qF \"$base\" \"$sources_md\" 2>/dev/null; then  # MUTANT5: reverted to basename substring"; else print }' "$SUT" > "$mutant5"
  if ! grep -q 'MUTANT5: reverted to basename substring' "$mutant5"; then
    echo "  FAIL  could not build LEVEL 5 mutant (registration line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/bad-substring-collision"   # reuse the collision fixture (BAD 6)
    bash "$mutant5" "$d" >/dev/null 2>&1; m5got=$?
    if [ "$m5got" = 0 ]; then
      printf '  PASS  %-42s (mutant false-passes → collision test has teeth)\n' "teeth: LEVEL 5 substring mutant exit 0"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 0). BAD 6 does NOT depend on the exact match — THEATER.\n' "teeth: LEVEL 5" "$m5got"; fail=$((fail+1))
    fi
  fi

  # FIX A teeth: revert the File-cell normalization to space+backtick only (drop tab-stripping) and assert the
  #   tab-padded fixture (GOOD 8) then FALSE-ORPHANS — proving the tab trim is load-bearing on the HARD gate.
  echo "-- teeth proof: drop tab-stripping from registration, expect the tab-padded fixture to FALSE-ORPHAN --"
  mutantA="$TMP/verify-sources.MUTANTA.sh"
  sed 's|gsub(/\[`\[:blank:\]\]/|gsub(/[` ]/|' "$SUT" > "$mutantA"
  if ! grep -qF 'gsub(/[` ]/' "$mutantA"; then
    echo "  FAIL  could not build FIX A mutant (normalization line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/good-tab-padded-registration"   # reuse the tab-padded fixture (GOOD 8)
    bash "$mutantA" "$d" >/dev/null 2>&1; magot=$?
    if [ "$magot" = 1 ]; then
      printf '  PASS  %-42s (mutant false-orphans → tab-trim has teeth)\n' "teeth: FIX A mutant exit 1"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 1). GOOD 8 does NOT depend on tab-stripping — THEATER.\n' "teeth: FIX A" "$magot"; fail=$((fail+1))
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
