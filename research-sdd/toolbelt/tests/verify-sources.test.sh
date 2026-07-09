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

# GOOD (LEVEL 4) — a TAB-padded File cell in a hand-edited SOURCES.md must NOT spoof a FABRICATED-CITE.
#   The block genuinely cites ds.pdf; only the registry's File cell is tab-padded. Before the [:blank:]
#   fix the tab survived into the basename and the grep missed a real citation → spurious LEVEL 4 FAIL.
d="$TMP/good-tab-fcell"; mkdir -p "$d/sources"
block "$d/b-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — this block DOES cite the datasheet.'
: > "$d/sources/ds.pdf"
sources_registry "$d" "$(printf '|\tds.pdf\t| datasheet | http://x | 2026-01-01 | abcd123 | B1 |')"
assert_exit "$SUT" 0 "GOOD: tab-padded File cell is not a fabricated-cite (LEVEL 4)" "$d"

# ---------------------------------------------------------------------------
# LEVEL 1 LEGEND-STRIP — the header-legend false-positive. EVERY block opens with a blockquote LEGEND that
# DEFINES the markers (e.g. `> [CERT-a] = asserted by a source; [INFER] = deduction`). A plain `grep -lF`
# counts that legend as a preserved-source CITATION, so a legend-only corpus with no SOURCES.md FALSE-FAILS
# LEVEL 1 ("must register preserved sources"). The fix reuses verify-block.sh's positional legend-strip:
# count the marker only in the BODY that follows the leading `>` blockquote's closing `---` fence.

# BAD-TURNED-GOOD (RED-FIRST) — a block whose ONLY [CERT-a]/[CERT-doc] occurrence is the header legend, and no
#   other real cite, must NOT trip LEVEL 1. Today the legend is counted → doc+a>0 → false LEVEL 1 FAIL (exit 1).
d="$TMP/legend-only-no-registry"; mkdir -p "$d"
block "$d/lo-block1.md" \
  '# Block 1' \
  '> `[CERT-a]` = asserted by a source; `[CERT-doc]` = from a preserved doc; `[INFER]` = deduction.' \
  '' \
  '---' \
  '' \
  '## 1.1 [CERT] file.c:10 — a purely local claim; NO preserved source is actually cited in the body.'
assert_exit "$SUT" 0 "LEGEND-ONLY markers do not trip LEVEL 1" "$d"

# REAL-CITE GUARD — same legend, but the BODY genuinely uses [CERT-a] on a claim → the preserved marker is
#   REAL → LEVEL 1 must STILL fire with no SOURCES.md. Pins that the strip does not over-suppress real cites.
d="$TMP/legend-plus-real-cite"; mkdir -p "$d"
block "$d/lr-block1.md" \
  '# Block 1' \
  '> `[CERT-a]` = asserted by a source; `[CERT-doc]` = from a preserved doc; `[INFER]` = deduction.' \
  '' \
  '---' \
  '' \
  '## 1.1 [CERT-a] the datasheet asserts Vcc=3.3V — a REAL preserved-source citation in the body, no registry.'
assert_exit "$SUT" 1 "REAL body [CERT-a] still trips LEVEL 1 (no registry)" "$d"

# POSITIVE CONTROL — legend + a real body [CERT-a] cite, WITH a populated SOURCES.md → registry present →
#   LEVEL 1 satisfied → PASS (0). Confirms the strip did not disturb the registered-corpus happy path.
d="$TMP/legend-real-cite-registered"; mkdir -p "$d/sources"
block "$d/lc-block1.md" \
  '# Block 1' \
  '> `[CERT-a]` = asserted by a source; `[INFER]` = deduction.' \
  '' \
  '---' \
  '' \
  '## 1.1 [CERT-a] sources/ds.pdf asserts Vcc=3.3V — real body cite, and it is registered.'
: > "$d/sources/ds.pdf"
sources_registry "$d" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 | B1 |'
assert_exit "$SUT" 0 "legend + real cite WITH registry passes" "$d"

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
# LEVEL 6 — web-snapshot HASH integrity. LEVEL 5 proves a snapshot is registered + cited (chain of custody)
# but NEVER recomputes the sha256 the registry stores — so tampering/corruption of a preserved snapshot passes
# silently ("provenance-hash theatre"). LEVEL 6 makes the registered hash LOAD-BEARING: recompute sha256sum of
# the on-disk file and compare. FULL 64-hex mismatch → FAIL (rc=1). MISSING/placeholder/TRUNCATED → WARN only
# (fetch-doc.sh itself truncates to `${sha:0:16}…`, so legacy corpora must not be broken).

# BAD 7 — full-hash MISMATCH (tampered): registry pins a full 64-hex that does NOT match the file → CATCH (1).
#   [RED-FIRST] Today nothing recomputes, so this tampered snapshot FALSE-PASSES (exit 0) — the failing test.
d="$TMP/bad-hash-mismatch"; mkdir -p "$d"
block "$d/hx-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — registered but TAMPERED after the fact.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>body AFTER tampering — no longer matches the registered hash</div>'
wrong="0000000000000000000000000000000000000000000000000000000000000000"   # a valid 64-hex that cannot match
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | $wrong | B1 |"
assert_exit "$SUT" 1 "BAD: snapshot full-hash mismatch (tampered)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'hash-mismatch: sources/web-snapshots/foo.md' \
  && { printf '  PASS  %-42s (mismatch line printed)\n' "hash-mismatch line printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (mismatch line missing)\n' "hash-mismatch line printed"; fail=$((fail+1)); }

# GOOD 9 — full-hash MATCHES the file on disk → PASS (0), no mismatch. Compute the REAL hash into the registry.
d="$TMP/good-hash-match"; mkdir -p "$d"
block "$d/hm-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — registered with its real hash.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>immutable body — registry pins its true sha256</div>'
real="$(sha256sum "$d/sources/web-snapshots/foo.md" | cut -d' ' -f1)"
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | $real | B1 |"
assert_exit "$SUT" 0 "GOOD snapshot full-hash matches on disk" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -qE 'hash-mismatch|unverifiable-hash' \
  && { printf '  FAIL  %-42s (clean full hash flagged)\n' "matching full hash is quiet"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no false hash finding)\n' "matching full hash is quiet"; pass=$((pass+1)); }

# GOOD 10 (LEGACY) — `(unhashed; see file)` placeholder → WARN unverifiable-hash, NOT a FAIL (exit 0).
#   Breaking the dashboards-style unhashed corpus is forbidden; the WARN surfaces the debt without a hard fail.
d="$TMP/good-legacy-unhashed"; mkdir -p "$d"
block "$d/lu-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — legacy, unhashed registration.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>legacy body, registry never stored a hash</div>'
sources_registry "$d" '| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | (unhashed; see file) | B1 |'
assert_exit "$SUT" 0 "GOOD legacy unhashed snapshot (WARN not fail)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
{ printf '%s\n' "$out" | grep -q 'unverifiable-hash: sources/web-snapshots/foo.md' \
  && ! printf '%s\n' "$out" | grep -q 'hash-mismatch'; } \
  && { printf '  PASS  %-42s (WARN, no fail)\n' "unhashed → unverifiable-hash WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN missing or hard-failed)\n' "unhashed → unverifiable-hash WARN"; fail=$((fail+1)); }

# GOOD 11 (LEGACY) — TRUNCATED hash `04adf2b071e479b2…` (exactly what fetch-doc.sh writes) → WARN, NOT a FAIL (0).
d="$TMP/good-truncated-hash"; mkdir -p "$d"
block "$d/th-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — kit-truncated hash prefix.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>body with a display-truncated registered hash</div>'
sources_registry "$d" '| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | 04adf2b071e479b2… | B1 |'
assert_exit "$SUT" 0 "GOOD truncated hash snapshot (WARN not fail)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
{ printf '%s\n' "$out" | grep -q 'unverifiable-hash: sources/web-snapshots/foo.md' \
  && ! printf '%s\n' "$out" | grep -q 'hash-mismatch'; } \
  && { printf '  PASS  %-42s (truncated → WARN)\n' "truncated hash → unverifiable-hash WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (truncated WARN missing or failed)\n' "truncated hash → unverifiable-hash WARN"; fail=$((fail+1)); }

# REGRESSION GUARD — an ORPHAN snapshot (LEVEL 5 FAIL) must NOT ALSO get a LEVEL 6 hash line (no double-report).
#   Reuse the BAD 4 fixture: foo.md on disk, registry names nothing → orphan-snapshot only, no hash finding.
d="$TMP/bad-orphan-snapshot"   # built above (orphan, empty registry)
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -qE 'hash-mismatch|unverifiable-hash' \
  && { printf '  FAIL  %-42s (orphan double-reported by LEVEL 6)\n' "orphan not double-reported"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (LEVEL 6 stays out of it)\n' "orphan not double-reported"; pass=$((pass+1)); }

# ---------------------------------------------------------------------------
# INTEGRATION — drive the REAL producer (fetch-doc.sh) end-to-end, then TAMPER, then verify.
#   THE coverage that matters: LEVEL 6's unit fixtures hand-build full-hash rows, but the SANCTIONED producer is
#   fetch-doc.sh. If reg() truncates the sha256 CELL, every tool-made snapshot is only WARN-checkable and a
#   tampered snapshot FALSE-PASSES — LEVEL 6 is vacuous in the documented workflow. This registers a snapshot via
#   fetch-doc.sh (local file:// fetch, no network), tampers the on-disk file, and asserts verify-sources.sh
#   CATCHES it (rc=1, hash-mismatch). RED against a truncating producer; green once reg() stores the full hash.
FETCH="$HERE/../fetch-doc.sh"
if [ -f "$FETCH" ] && { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }; then
  d="$TMP/integration-producer"; mkdir -p "$d"
  src="$TMP/producer-src.html"; printf '<html><body><p>preserved evidence body</p></body></html>\n' > "$src"
  # REAL registration path: fetch-doc.sh web <url> <target> → sources/web-snapshots/<slug>.md + SOURCES.md row.
  bash "$FETCH" web "file://$src" "$d" >/dev/null 2>&1
  snap="$(find "$d/sources/web-snapshots" -type f -name '*.md' 2>/dev/null | head -1)"
  if [ -z "$snap" ] || [ ! -f "$d/sources/SOURCES.md" ]; then
    printf '  FAIL  %-42s (producer did not register a snapshot)\n' "integration: fetch-doc registered"; fail=$((fail+1))
  else
    # a block cites it so the ONLY finding is the hash state (keeps uncited-snapshot WARN out of the picture)
    block "$d/ip-block1.md" '# Block 1' "## 1.1 cites sources/${snap#"$d"/sources/} — the registered snapshot."
    assert_exit "$SUT" 0 "integration: fresh producer registration verifies" "$d"
    # TAMPER the preserved file — its bytes no longer match the hash reg() stored.
    printf '<html><body><p>TAMPERED body — bytes changed after registration</p></body></html>\n' > "$snap"
    assert_exit "$SUT" 1 "integration: tampered producer snapshot caught" "$d"
    out="$(bash "$SUT" "$d" 2>&1)"
    printf '%s\n' "$out" | grep -q 'hash-mismatch' \
      && { printf '  PASS  %-42s (real producer path is enforced)\n' "integration: hash-mismatch on tamper"; pass=$((pass+1)); } \
      || { printf '  FAIL  %-42s (producer hash not verifiable — truncated cell?)\n' "integration: hash-mismatch on tamper"; fail=$((fail+1)); }
  fi
else
  printf '  SKIP  %-42s (fetch-doc.sh or curl/wget unavailable)\n' "integration: producer end-to-end"
fi

# ---------------------------------------------------------------------------
# TEMPLATE-ANCHOR — a block-shaped kit TEMPLATE must never anchor a phantom corpus root. A dir whose
#   ONLY block-shaped file is templates/block.template.md (placeholder, carries a [CERT-doc] legend marker
#   but no SOURCES.md) must NOT resolve that template dir as the corpus root. RED before the fix: the
#   template was the shallowest *block*.md → anchored corpus=templates/, and its placeholder [CERT-doc]
#   marker tripped a phantom LEVEL 1 FAIL (exit 1). Fixed: the resolution find excludes *.template.md →
#   no anchor → corpus=target (no real blocks, no markers) → clean PASS (0).
d="$TMP/template-anchor"; mkdir -p "$d/templates"
block "$d/templates/block.template.md" '# <SUBJECT> — Block <k>' '## <k>.1 [CERT-doc] sources/<file> — placeholder legend, NOT a real citation.'
assert_exit "$SUT" 0 "TEMPLATE: block.template.md does not anchor" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'corpus root: templates/' \
  && { printf '  FAIL  %-42s (template anchored a phantom corpus)\n' "template did not anchor corpus root"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no phantom corpus root)\n' "template did not anchor corpus root"; pass=$((pass+1)); }

# POSITIVE CONTROL — a REAL block alongside a template must still anchor on the real block. foo-block1.md
#   (clean, no preserved markers) coexists with block.template.md in the SAME subdir; resolution must pick
#   that dir and pass. Pins that the *.template.md exclusion does not drop real blocks from resolution.
d="$TMP/template-plus-real"; mkdir -p "$d/corpus"
block "$d/corpus/foo-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim, no external source.'
block "$d/corpus/block.template.md" '# <SUBJECT> — Block <k>' '## <k>.1 placeholder legend.'
assert_exit "$SUT" 0 "POSITIVE: real block anchors, template ignored" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s\n' "$out" | grep -q 'corpus root: corpus/' \
  && { printf '  PASS  %-42s (real block anchored corpus/)\n' "real block still anchors corpus/"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (real block did not anchor)\n' "real block still anchors corpus/"; fail=$((fail+1)); }

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

  # LEVEL 6 teeth: neutralize the hash comparison and assert the tampered fixture (BAD 7) then FALSE-PASSES —
  #   proving the recompute-and-compare is load-bearing (without it the registered sha256 is dead weight).
  echo "-- teeth proof: neutralize the LEVEL 6 hash compare, expect the tampered fixture to FALSE-PASS --"
  mutant6="$TMP/verify-sources.MUTANT6.sh"
  awk '{ if ($0 ~ /HASH-INTEGRITY compare/) print "      if false; then  # MUTANT6: hash compare neutralized"; else print }' "$SUT" > "$mutant6"
  if ! grep -q 'MUTANT6: hash compare neutralized' "$mutant6"; then
    echo "  FAIL  could not build LEVEL 6 mutant (compare line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/bad-hash-mismatch"   # reuse the tampered fixture (BAD 7)
    bash "$mutant6" "$d" >/dev/null 2>&1; m6got=$?
    if [ "$m6got" = 0 ]; then
      printf '  PASS  %-42s (mutant false-passes → hash check has teeth)\n' "teeth: LEVEL 6 compare mutant exit 0"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 0). BAD 7 does NOT depend on the recompute — THEATER.\n' "teeth: LEVEL 6" "$m6got"; fail=$((fail+1))
    fi
  fi

  # LEVEL 1 legend-strip teeth: revert the body extraction to the WHOLE FILE (count the legend again) and
  #   assert the legend-only fixture then FALSE-FAILS (exit 1) — proving the positional strip is load-bearing.
  echo "-- teeth proof: revert LEVEL 1 to whole-file marker count, expect legend-only to FALSE-FAIL --"
  mutantL="$TMP/verify-sources.MUTANTL.sh"
  awk '{ if ($0 ~ /LEGEND-STRIP: count markers/) print "      body=\"$(cat \"$f\")\"  # MUTANTL: legend strip reverted"; else print }' "$SUT" > "$mutantL"
  if ! grep -q 'MUTANTL: legend strip reverted' "$mutantL"; then
    echo "  FAIL  could not build LEVEL 1 mutant (legend-strip line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/legend-only-no-registry"   # reuse the legend-only fixture
    bash "$mutantL" "$d" >/dev/null 2>&1; mlgot=$?
    if [ "$mlgot" = 1 ]; then
      printf '  PASS  %-42s (mutant false-fails → legend-strip has teeth)\n' "teeth: LEVEL 1 whole-file mutant exit 1"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 1). Legend-only does NOT depend on the strip — THEATER.\n' "teeth: LEVEL 1" "$mlgot"; fail=$((fail+1))
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
