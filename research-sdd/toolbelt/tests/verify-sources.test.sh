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
grep -q 'orphan-snapshot' <<<"$out" \
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
grep -q 'uncited-snapshot' <<<"$out" \
  && { printf '  PASS  %-42s (WARN line present)\n' "uncited-snapshot line printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN line missing)\n' "uncited-snapshot line printed"; fail=$((fail+1)); }

# BAD 5 — snapshots on disk but NO SOURCES.md at all → every snapshot is an orphan (LEVEL 5) → CATCH (1)
#   Deliberately NO [CERT-doc]/[CERT-a] markers, so LEVEL 1 stays silent and LEVEL 5 is the failing level.
d="$TMP/bad-snapshot-no-registry"; mkdir -p "$d"
block "$d/nr-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim, no preserved markers.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>raw body, provenance now unrecoverable</div>'
assert_exit "$SUT" 1 "BAD: snapshots on disk, no SOURCES.md" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'orphan-snapshot' <<<"$out" \
  && { printf '  PASS  %-42s (LEVEL 5 is the failing level)\n' "no-registry → orphan-snapshot line"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (LEVEL 5 did NOT fire)\n' "no-registry → orphan-snapshot line"; fail=$((fail+1)); }

# GOOD 4 — normal corpus, NO web-snapshots/ dir → PASS (0), no snapshot output
d="$TMP/good-no-snapshot-dir"; mkdir -p "$d"
block "$d/ns-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
assert_exit "$SUT" 0 "GOOD no web-snapshots/ dir" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'web-snapshots:' <<<"$out" \
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
grep -q 'orphan-snapshot: sources/web-snapshots/report.md' <<<"$out" \
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
grep -q 'uncited-snapshot' <<<"$out" \
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
grep -q 'uncited-snapshot' <<<"$out" \
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
grep -q 'uncited-snapshot' <<<"$out" \
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
grep -q 'orphan-snapshot' <<<"$out" \
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
grep -q 'uncited-snapshot' <<<"$out" \
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
grep -q 'hash-mismatch: sources/web-snapshots/foo.md' <<<"$out" \
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
grep -qE 'hash-mismatch|unverifiable-hash' <<<"$out" \
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
{ grep -q 'unverifiable-hash: sources/web-snapshots/foo.md' <<<"$out" \
  && ! grep -q 'hash-mismatch' <<<"$out"; } \
  && { printf '  PASS  %-42s (WARN, no fail)\n' "unhashed → unverifiable-hash WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN missing or hard-failed)\n' "unhashed → unverifiable-hash WARN"; fail=$((fail+1)); }

# GOOD 11 — TRUNCATED hash (16 chars, matching the real file) → VERIFIED, exit 0, no finding.
#   Pre-prefix-comparison: any truncated hash was WARN "unverifiable-hash". Post-comparison:
#   a truncated-but-matching prefix is accepted as VERIFIED (no warn, no fail). Use the REAL
#   first-16-chars of the file's sha256 so the prefix comparison succeeds.
d="$TMP/good-truncated-hash"; mkdir -p "$d"
block "$d/th-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — kit-truncated hash prefix.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>body with a display-truncated registered hash</div>'
real_trunc="$(sha256sum "$d/sources/web-snapshots/foo.md" | cut -d' ' -f1 | cut -c1-16)"
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | ${real_trunc}… | B1 |"
assert_exit "$SUT" 0 "GOOD truncated hash (matching prefix, verified)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'hash-mismatch|prefix-mismatch|unverifiable-hash' <<<"$out" \
  && { printf '  FAIL  %-42s (matching prefix falsely flagged)\n' "truncated matching → no finding"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no finding for matching prefix)\n' "truncated matching → no finding"; pass=$((pass+1)); }

# REGRESSION GUARD — an ORPHAN snapshot (LEVEL 5 FAIL) must NOT ALSO get a LEVEL 6 hash line (no double-report).
#   Reuse the BAD 4 fixture: foo.md on disk, registry names nothing → orphan-snapshot only, no hash finding.
d="$TMP/bad-orphan-snapshot"   # built above (orphan, empty registry)
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'hash-mismatch|unverifiable-hash' <<<"$out" \
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
    grep -q 'hash-mismatch' <<<"$out" \
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
grep -q 'corpus root: templates/' <<<"$out" \
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
grep -q 'corpus root: corpus/' <<<"$out" \
  && { printf '  PASS  %-42s (real block anchored corpus/)\n' "real block still anchors corpus/"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (real block did not anchor)\n' "real block still anchors corpus/"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# B4 — MULTI-FOCUS FABRICATED-CITE FIX.
# Before the fix: find ... | head -1 picked ONE matching *blockN.md and false-FAILed when the chosen
# file was the other focus's block (which didn't cite the source). Fix: check ALL matching files.

# B4-GOOD: two focus block files match *block1.md. Source is cited in ONLY ONE (focus-a). SUT must PASS.
# Before fix: if head-1 picked focus-b-block1.md (no cite), false FABRICATED-CITE → exit 1 (wrong).
# After fix:  all files checked; focus-a-block1.md has the cite → exit 0 (correct).
d="$TMP/b4-multi-focus-good"; mkdir -p "$d"
# citing file created FIRST (lower inode → returned first by find on tmpfs)
block "$d/focus-a-block1.md" '# Block 1 (focus-a)' '## 1.1 cites sources/web-snapshots/ext.md — the CITED file.'
# non-citing file created SECOND
block "$d/focus-b-block1.md" '# Block 1 (focus-b)' '## 1.1 discusses internal stuff, never references the external source.'
mkdir -p "$d/sources/web-snapshots"
printf '<div>body</div>\n' > "$d/sources/web-snapshots/ext.md"
real_b4="$(sha256sum "$d/sources/web-snapshots/ext.md" | cut -d' ' -f1)"
sources_registry "$d" "| web-snapshots/ext.md | web-snapshot | http://x | 2026-01-01 | $real_b4 | B1 |"
assert_exit "$SUT" 0 "B4-GOOD: multi-focus — cite in one block1.md suffices (no false FABRICATED-CITE)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'FABRICATED-CITE' <<<"$out" \
  && { printf '  FAIL  %-42s (false FABRICATED-CITE emitted)\n' "B4-GOOD: no FABRICATED-CITE"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (FABRICATED-CITE absent)\n' "B4-GOOD: no false FABRICATED-CITE"; pass=$((pass+1)); }

# B4-BAD: two block files match *block1.md, but NEITHER cites the source → genuine FABRICATED-CITE (exit 1).
# This ensures the all-files check isn't completely disabled.
d="$TMP/b4-multi-focus-bad"; mkdir -p "$d"
block "$d/focus-a-block1.md" '# Block 1 (focus-a)' '## 1.1 discusses something else entirely.'
block "$d/focus-b-block1.md" '# Block 1 (focus-b)' '## 1.1 also does not mention the external source.'
mkdir -p "$d/sources/web-snapshots"
printf '<div>body</div>\n' > "$d/sources/web-snapshots/ext.md"
real_b4b="$(sha256sum "$d/sources/web-snapshots/ext.md" | cut -d' ' -f1)"
sources_registry "$d" "| web-snapshots/ext.md | web-snapshot | http://x | 2026-01-01 | $real_b4b | B1 |"
assert_exit "$SUT" 1 "B4-BAD: neither multi-focus block1.md cites source → genuine FABRICATED-CITE" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'FABRICATED-CITE.*none of 2' <<<"$out" \
  && { printf '  PASS  %-42s (genuine FABRICATED-CITE with count)\n' "B4-BAD: FABRICATED-CITE names file count"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (FABRICATED-CITE line missing or wrong)\n' "B4-BAD: FABRICATED-CITE names file count"; fail=$((fail+1)); }

# B4-WARN: SOURCES.md claims B5, but no *block5.md exists at all → WARN (not FAIL, exit 0).
d="$TMP/b4-no-block"; mkdir -p "$d"
block "$d/focus-a-block1.md" '# Block 1' '## 1.1 only block 1 exists; no block 5.'
mkdir -p "$d/sources/web-snapshots"
printf '<div>body</div>\n' > "$d/sources/web-snapshots/ext.md"
real_b4c="$(sha256sum "$d/sources/web-snapshots/ext.md" | cut -d' ' -f1)"
sources_registry "$d" "| web-snapshots/ext.md | web-snapshot | http://x | 2026-01-01 | $real_b4c | B5 |"
assert_exit "$SUT" 0 "B4-WARN: no *block5.md on disk → WARN (naming mismatch), not FAIL" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*block5.*naming mismatch' <<<"$out" \
  && { printf '  PASS  %-42s (WARN emitted for missing block file)\n' "B4-WARN: naming-mismatch WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN missing)\n' "B4-WARN: naming-mismatch WARN"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# LEVEL 6 — PREFIX COMPARISON. LEVEL 6 verifies full 64-hex registrations. But
# legacy or hand-edited corpora may store only a PREFIX (e.g. `04adf2b071e479b2…`).
# A prefix of ≥ 8 hex chars is verifiable by prefix: recompute sha256 and check the
# disk hash starts with the registered prefix. Mismatch → content changed → FAIL.
# Prefix < 8 chars → WEAK warn. Tool absent → explicit notice (never a silent pass).

# BAD 8 — prefix-mismatch (RED-FIRST): truncated 16-char prefix that does NOT match
#   the file on disk → FAIL (rc=1).
#   [Before prefix comparison: truncated → WARN + exit 0 — the gap this closes.]
d="$TMP/bad-prefix-mismatch"; mkdir -p "$d"
block "$d/pm-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — prefix mismatch case.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>content that hashes to something other than all-zeros</div>'
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | 0000000000000000… | B1 |"
assert_exit "$SUT" 1 "BAD: prefix-mismatch (truncated prefix does not match file)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'prefix-mismatch: sources/web-snapshots/foo.md' <<<"$out" \
  && { printf '  PASS  %-42s (prefix-mismatch line printed)\n' "prefix-mismatch line printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (prefix-mismatch line missing)\n' "prefix-mismatch line printed"; fail=$((fail+1)); }

# GOOD 13 — prefix too short (< 8 hex chars): WEAK warn, not a FAIL, exit 0.
#   `a1b2c3d` = 7 chars (28 bits); below MIN_PREFIX=8. Surface the debt without hard-failing.
d="$TMP/good-prefix-short"; mkdir -p "$d"
block "$d/ps-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md — short prefix case.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>some content</div>'
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | a1b2c3d… | B1 |"
assert_exit "$SUT" 0 "GOOD: prefix too short (7 chars < 8) → WEAK warn (exit 0)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'unverifiable-hash: sources/web-snapshots/foo.md' <<<"$out" \
  && { printf '  PASS  %-42s (short prefix → unverifiable-hash WARN)\n' "short prefix emits WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (short prefix WARN missing)\n' "short prefix emits WARN"; fail=$((fail+1)); }

# GOOD 14 — sha256sum unavailable: notice emitted, exit 0 (cannot verify but not a failure).
#   A run that verified nothing because the tool was absent must NOT look like a clean pass.
#   On systems where sha256sum shares /usr/bin with every other tool, PATH filtering cannot
#   isolate it. Patch the availability check in the SUT to return false — same pattern as
#   the other mutation controls — to prove the elif-branch fires and emits the notice.
d="$TMP/sha256-unavailable"; mkdir -p "$d"
block "$d/nu-block1.md" '# Block 1' '## 1.1 cites sources/web-snapshots/foo.md.'
snapshot "$d/sources/web-snapshots/foo.md" '<div>body</div>'
sources_registry "$d" "| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | (unhashed) | B1 |"
_patched_sut="$TMP/sut-no-sha256.sh"
sed 's/command -v sha256sum >/false >/' "$SUT" > "$_patched_sut"
_sha_out="$(bash "$_patched_sut" "$d" 2>&1)"; _sha_rc=$?
if [ "$_sha_rc" = 0 ]; then
  printf '  PASS  %-42s (exit 0 with sha256sum patched absent)\n' "sha256sum unavailable: exit 0"; pass=$((pass+1))
else
  printf '  FAIL  %-42s exit %s (expected 0)\n' "sha256sum unavailable: exit 0" "$_sha_rc"; fail=$((fail+1))
fi
grep -qE 'sha256sum not found|cannot be checked' <<<"$_sha_out" \
  && { printf '  PASS  %-42s (notice emitted)\n' "sha256sum unavailable: notice printed"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (notice missing — silent pass)\n' "sha256sum unavailable: notice printed"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# DEFECT 1 — malformed row (wrong column count) must WARN with line number; loops must skip it.
# A 5-col row shifts sha256 and Blocks cells left; the field-guard in LEVEL 4 and LEVEL 6
# skips the row (preventing misparse) and the pre-check warns. Severity = WARN (§8: registry
# finding, not a broken instrument — the human must fix the registry).

# D1-WARN-1: a 5-col row (sha256 col missing) emits WARN + line number, exit 0.
d="$TMP/d1-malformed-row"; mkdir -p "$d/sources/manuals"
block "$d/d1-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
{ printf '# Sources\n\n'
  printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| manuals/guide.pdf | manual | http://x | 2026-01-01 | B1 |\n'
} > "$d/sources/SOURCES.md"     # 5-col data row: sha256 missing, Blocks col = B1
: > "$d/sources/manuals/guide.pdf"
assert_exit "$SUT" 0 "D1-WARN: 5-col row exits 0 (WARN, not fail)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*malformed' <<<"$out" \
  && { printf '  PASS  %-42s (malformed-row WARN emitted)\n' "D1-WARN: malformed WARN present"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (no malformed-row WARN)\n' "D1-WARN: malformed WARN present"; fail=$((fail+1)); }
grep -qE 'WARN.*SOURCES\.md line [0-9]' <<<"$out" \
  && { printf '  PASS  %-42s (WARN includes SOURCES.md line number)\n' "D1-WARN: line number in WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN missing SOURCES.md line number)\n' "D1-WARN: line number in WARN"; fail=$((fail+1)); }

# D1-SKIP-L6: a 5-col web-snapshot row must NOT produce "unverifiable-hash" from LEVEL 6.
# Before fix: LEVEL 6 reads the Blocks cell ("B5") as sha256 → "prefix 2 chars < 8" misleading WARN.
# After fix: the L6-FIELD-GUARD skips the row; only the pre-check malformed WARN appears.
d="$TMP/d1-skip-l6"; mkdir -p "$d/sources"
block "$d/d1l6-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim.'
{ printf '# Sources\n\n'
  printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| web-snapshots/foo.md | web-snapshot | http://x | 2026-01-01 | B5 |\n'
} > "$d/sources/SOURCES.md"     # 5-col: "B5" lands in the sha256 slot in the buggy version
snapshot "$d/sources/web-snapshots/foo.md" '<div>body</div>'
assert_exit "$SUT" 0 "D1-SKIP-L6: 5-col web-snap row, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'unverifiable-hash' <<<"$out" \
  && { printf '  FAIL  %-42s (misleading hash WARN present — row not skipped by field-guard)\n' "D1-SKIP-L6: no misleading unverifiable-hash"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no misleading hash output for malformed row)\n' "D1-SKIP-L6: no misleading unverifiable-hash"; pass=$((pass+1)); }

# DEFECT 2 visibility — non-web-snapshot rows with on-disk files and hash-like cells must appear
# in a "not hash-verified" count (§7: the operator must be able to see the uncovered surface).

# D2-VISIBLE: a manuals/ row with a truncated-hash cell and an on-disk file → count line emitted.
d="$TMP/d2-visible-skipped"; mkdir -p "$d/sources/manuals"
block "$d/d2-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/manuals/guide.pdf §1 — a manual.'
: > "$d/sources/manuals/guide.pdf"
sources_registry "$d" "| manuals/guide.pdf | manual | http://x | 2026-01-01 | abcdef01… | B1 |"
assert_exit "$SUT" 0 "D2-VISIBLE: non-web-snap hashed row, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'not hash-verified' <<<"$out" \
  && { printf '  PASS  %-42s (unchecked hash count reported)\n' "D2-VISIBLE: non-web-snap hash count line"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (unchecked hash count NOT reported)\n' "D2-VISIBLE: non-web-snap hash count line"; fail=$((fail+1)); }

# D2-EMPTY: empty registry → zero non-web-snapshot hashed rows → no count line.
# Tests the three-state distinction: "no rows" vs "rows but no hash" vs "rows with hash".
d="$TMP/d2-no-hashed-rows"; mkdir -p "$d"
block "$d/d2n-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim.'
sources_registry "$d"   # empty registry (no data rows at all)
assert_exit "$SUT" 0 "D2-EMPTY: empty registry, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'not hash-verified' <<<"$out" \
  && { printf '  FAIL  %-42s (count line emitted for empty registry — §7 false positive)\n' "D2-EMPTY: no count for empty registry"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no spurious count line)\n' "D2-EMPTY: no count for empty registry"; pass=$((pass+1)); }

# D1-SECOND-TABLE: SOURCES.md with a conforming 6-col registry followed by a secondary
# table under a heading must produce ZERO malformed or schema WARNs. The secondary table
# rows appear after a non-table line and are outside the registry block — the check must
# never reach them. This is the regression guard for the hifref false-positive defect:
# the all-rows awk flagged every row in the 2-col secondary table (10 false positives).
d="$TMP/d1-second-table"; mkdir -p "$d/sources/web-snapshots"
block "$d/d1st-block1.md" '# Block 1' '## 1.1 [CERT] sources/web-snapshots/page.html §2 — snapshot.'
snapshot "$d/sources/web-snapshots/page.html" '<div>body</div>'
{ printf '# External sources\n\n'
  printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| web-snapshots/page.html | web-snapshot | http://ex.com | 2026-01-01 | 280dbb9eb12b45d1\xe2\x80\xa6 | B1 |\n'
  printf '\n## Local resources (not preserved externally)\n\n'
  printf '| Archivo | Qu\xc3\xa9 aporta |\n'
  printf '|---|---|\n'
  printf '| local/notes.txt | Contextual background |\n'
} > "$d/sources/SOURCES.md"
assert_exit "$SUT" 0 "D1-SECOND-TABLE: secondary table, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*(malformed|schema)' <<<"$out" \
  && { printf '  FAIL  %-42s (false-positive WARN on secondary table rows)\n' "D1-SECOND-TABLE: no WARN on secondary"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no spurious WARN for secondary table rows)\n' "D1-SECOND-TABLE: no WARN on secondary"; pass=$((pass+1)); }

# D1-SCHEMA-WARN: a non-conforming registry header (fewer than 6 columns) → exactly ONE
# schema-level WARN per file; rows internally consistent with the non-conforming header
# must NOT generate per-row WARNs. Models the Alerton shape: 4-col registry header, rows
# all consistently 4 columns. One WARN tells the operator to fix the schema; nine per-row
# WARNs on rows that agree with their own header would be noise.
d="$TMP/d1-schema-warn"; mkdir -p "$d/sources/docs"
block "$d/d1sw-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim.'
: > "$d/sources/docs/file.pdf"; : > "$d/sources/docs/other.pdf"
{ printf '# External sources\n\n'
  printf '| File | Type | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|\n'
  printf '| docs/file.pdf | document | abcde123 | B1 |\n'
  printf '| docs/other.pdf | document | 98765432 | B1 |\n'
} > "$d/sources/SOURCES.md"
assert_exit "$SUT" 0 "D1-SCHEMA-WARN: non-conforming header, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
schema_warns=$(grep -c 'schema non-conforming' <<<"$out" || true)
row_warns=$(grep -c 'WARN.*malformed row' <<<"$out" || true)
[ "$schema_warns" -eq 1 ] \
  && { printf '  PASS  %-42s (exactly 1 schema WARN)\n' "D1-SCHEMA-WARN: one schema WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (expected 1 schema WARN, got %d)\n' "D1-SCHEMA-WARN: one schema WARN" "$schema_warns"; fail=$((fail+1)); }
[ "$row_warns" -eq 0 ] \
  && { printf '  PASS  %-42s (zero per-row malformed WARNs)\n' "D1-SCHEMA-WARN: no per-row WARNs"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (expected 0 per-row WARNs, got %d)\n' "D1-SCHEMA-WARN: no per-row WARNs" "$row_warns"; fail=$((fail+1)); }

# D1-CLEAN: fully conforming 6-col registry with well-formed data rows → zero malformed
# or schema WARNs. The explicit "clean" regression guard (fourth shape).
d="$TMP/d1-clean"; mkdir -p "$d/sources/manuals"
block "$d/d1c-block1.md" '# Block 1' '## 1.1 [CERT] sources/manuals/guide.pdf \xc2\xa73 — manual.'
: > "$d/sources/manuals/guide.pdf"
sources_registry "$d" "| manuals/guide.pdf | manual | http://x | 2026-01-01 | aabbccdd01234567\xe2\x80\xa6 | B1 |"
assert_exit "$SUT" 0 "D1-CLEAN: clean registry, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*(malformed|schema)' <<<"$out" \
  && { printf '  FAIL  %-42s (spurious WARN on clean conforming registry)\n' "D1-CLEAN: no WARN on clean registry"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no spurious WARN for clean conforming registry)\n' "D1-CLEAN: no WARN on clean registry"; pass=$((pass+1)); }

# ---------------------------------------------------------------------------
# APPENDED-ROWS — the fetch-doc.sh reg() appended-rows pattern. The fleet's registries
# were built by an old reg() that appends rows at EOF, AFTER ## Notes / ## Structure
# headings, leaving rows that a block-scoped parser would never see. Real shape from
# gateway-ug67/sources/SOURCES.md (documented in fetch-doc.sh:23-28):
#
#   | File | Type | ... | sha256 | Blocks |
#   |---|...|
#   | web-snapshots/ok.md | ... |           ← primary-block rows (before ## Notes)
#   ## Notes
#   ## Structure
#   | web-snapshots/appended.md | ... |     ← appended rows, no header of their own
#
# A parser anchored to the first registry block never reaches the appended rows. The
# L4 and L6 loops scan the FULL file (done < "$sources_md") to cover them. Without that,
# a hash-mismatch in an appended row silently false-passes — this fixture catches it.
d="$TMP/appended-rows-fail"; mkdir -p "$d/sources/web-snapshots"
block "$d/ar-block1.md" '# Block 1' \
  '## 1.1 cites sources/web-snapshots/ok.md and sources/web-snapshots/appended.md'
snapshot "$d/sources/web-snapshots/ok.md"       '<div>ok content — hash registered correctly</div>'
snapshot "$d/sources/web-snapshots/appended.md" '<div>appended content — registered hash is wrong</div>'
_ar_ok_hash="$(sha256sum "$d/sources/web-snapshots/ok.md" | cut -d' ' -f1)"
_ar_wrong="0000000000000000000000000000000000000000000000000000000000000000"
{ printf '# External sources preserved\n\n'
  printf '| File | Type | Origin (URL / channel) | Date (UTC) | sha256 | Blocks that cite it |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| web-snapshots/ok.md | web-snapshot | http://x | 2026-01-01 | %s | B1 |\n' "$_ar_ok_hash"
  printf '\n## Notes\n\nNo additional notes.\n\n## Structure\n\n'
  printf '| web-snapshots/appended.md | web-snapshot | http://y | 2026-01-01 | %s | B1 |\n' "$_ar_wrong"
} > "$d/sources/SOURCES.md"
assert_exit "$SUT" 1 "APPENDED-ROWS: appended-row hash-mismatch caught" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'hash-mismatch.*appended.md' <<<"$out" \
  && { printf '  PASS  %-42s (full-file scan reported the appended-row mismatch)\n' "APPENDED-ROWS: hash-mismatch line present"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (hash-mismatch line missing — appended row not reached)\n' "APPENDED-ROWS: hash-mismatch line present"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# SIGPIPE-RACE DETERMINISM — count_marker must return the same count on every run.
# The buggy printf|grep pipeline race: printf starts writing a 400KB body, grep exits
# as soon as it finds the match on line 2 (~30 bytes), the read end of the pipe closes,
# printf gets SIGPIPE (exit 141), set -o pipefail makes the pipeline exit non-zero, &&
# does not fire, and the count is NOT incremented despite the match. The race is 100%
# reliable at 400KB (verified: 0/200 matches on the pipeline form against this body).
# The herestring fix (grep -qF "$marker" <<< "$body") has no pipe, so no SIGPIPE.
d="$TMP/sigpipe-det"; mkdir -p "$d"
# [CERT-doc] on line 2, followed by 400KB of filler. No legend fence → whole file is body.
# grep exits immediately on line 2, leaving printf to SIGPIPE on the remaining 400KB.
_sp_pad="$(head -c 409600 /dev/zero | tr '\0' 'x')"
printf '# Block 1\n## 1.1 [CERT-doc] key finding — large-body determinism probe.\n%s\n' "$_sp_pad" \
  > "$d/sd-block1.md"
sources_registry "$d"   # SOURCES.md present so LEVEL 1 does not fail (doc > 0 requires registry)
# Run 20 times; assert count is 1 each time (correct AND stable).
_sprev="" ; _sstable=1
for _si in $(seq 1 20); do
  _sout="$(bash "$SUT" "$d" 2>&1)"
  _sdoc="$(printf '%s' "$_sout" | grep -oE '\[CERT-doc\] [0-9]+' | grep -oE '[0-9]+')"
  if [ -n "$_sprev" ] && [ "$_sdoc" != "$_sprev" ]; then _sstable=0; break; fi
  _sprev="$_sdoc"
done
if [ "$_sstable" -eq 1 ] && [ "${_sprev:-}" = "1" ]; then
  printf '  PASS  %-42s ([CERT-doc] 1 × 20 runs — herestring is deterministic)\n' "SIGPIPE-RACE: count stable and correct"
  pass=$((pass+1))
else
  printf '  FAIL  %-42s (expected [CERT-doc] 1 × 20 runs, got %s on run %s)\n' "SIGPIPE-RACE: count stable and correct" "${_sprev:-empty}" "$_si"
  fail=$((fail+1))
fi

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

  # B4 teeth: disable the multi-file citation check entirely (_cited_ok always starts at 1, so
  # FABRICATED-CITE never fires). The B4-BAD fixture (neither block file cites the source, so the real SUT
  # exits 1) must then FALSE-PASS (exit 0), proving the _cited_ok=0 initialization + loop check are load-bearing.
  echo "-- teeth proof: B4 — disable citation check (_cited_ok always 1), expect BAD fixture to FALSE-PASS --"
  mutantB4="$TMP/verify-sources.MUTANTB4.sh"
  sed 's/_cited_ok=0$/_cited_ok=1  # MUTANT-B4: check disabled/' "$SUT" > "$mutantB4"
  if ! grep -q 'MUTANT-B4: check disabled' "$mutantB4"; then
    echo "  FAIL  could not build B4 mutant (_cited_ok line not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/b4-multi-focus-bad"   # reuse: neither block1.md cites ext.md → real SUT exits 1
    bash "$mutantB4" "$d" >/dev/null 2>&1; mb4got=$?
    if [ "$mb4got" = 0 ]; then
      printf '  PASS  %-42s (disabled mutant false-passes → citation loop is load-bearing)\n' "teeth: B4 check-disabled mutant exit 0"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 0) — citation check may not depend on _cited_ok init (THEATER).\n' "teeth: B4" "$mb4got"; fail=$((fail+1))
    fi
  fi

  # PREFIX-COMPARISON teeth: neutralize the disk_pfx computation so it always equals pfx_lower —
  #   meaning the comparison always succeeds. BAD 8 (16-char prefix that doesn't match the file)
  #   must then FALSE-PASS (exit 0), proving the PREFIX-COMPARISON is load-bearing.
  echo "-- teeth proof: neutralize PREFIX-COMPARISON, expect BAD 8 to FALSE-PASS --"
  mutant_pfx="$TMP/verify-sources.MUTANT-PFX.sh"
  awk '{ if ($0 ~ /PREFIX-COMPARISON compare/) print "            disk_pfx=\"$pfx_lower\"  # MUTANT-PFX: comparison neutralized"; else print }' "$SUT" > "$mutant_pfx"
  if ! grep -q 'MUTANT-PFX: comparison neutralized' "$mutant_pfx"; then
    echo "  FAIL  could not build PREFIX mutant (sentinel not found — did the SUT change?)"; fail=$((fail+1))
  else
    d="$TMP/bad-prefix-mismatch"   # reuse BAD 8: prefix 0000000000000000… never matches real content
    bash "$mutant_pfx" "$d" >/dev/null 2>&1; m_pfx_got=$?
    if [ "$m_pfx_got" = 0 ]; then
      printf '  PASS  %-42s (mutant false-passes → prefix check has teeth)\n' "teeth: PREFIX-COMPARISON mutant exit 0"; pass=$((pass+1))
    else
      printf '  FAIL  %-42s mutant exit %s (expected 0). BAD 8 not dependent on prefix compare.\n' "teeth: PREFIX-COMPARISON" "$m_pfx_got"; fail=$((fail+1))
    fi
  fi

  # D1 teeth: disable the L6-FIELD-GUARD (the sentinel that skips malformed rows in LEVEL 6).
  #   The D1-SKIP-L6 fixture has a 5-col web-snapshot row with "B5" in the sha256 slot. With the
  #   guard disabled, LEVEL 6 processes it and emits "unverifiable-hash" (reads "B5" as a 2-char
  #   hex prefix < MIN_PREFIX). With the guard active, the row is skipped and no hash output appears.
  #   bash -n validated first: a mutant with a syntax error never runs, proving nothing (THEATER).
  echo "-- teeth proof: D1 — disable L6-FIELD-GUARD, expect D1-SKIP-L6 to produce misleading unverifiable-hash --"
  mutant_d1="$TMP/verify-sources.MUTANT-D1.sh"
  awk '{ if ($0 ~ /L6-FIELD-GUARD/) print "  pipes=\"${_raw//[^|]/}\"; [ 1 -ne 1 ] && continue   # MUTANT-D1: L6 guard disabled"; else print }' "$SUT" > "$mutant_d1"
  if ! grep -q 'MUTANT-D1: L6 guard disabled' "$mutant_d1"; then
    echo "  FAIL  could not build D1 mutant (L6-FIELD-GUARD sentinel not found — did the SUT change?)"; fail=$((fail+1))
  else
    bash -n "$mutant_d1" 2>/dev/null; d1_bn=$?
    if [ "$d1_bn" -ne 0 ]; then
      echo "  FAIL  D1 mutant does not parse (bash -n failed) — control would pass for the wrong reason (THEATER)"; fail=$((fail+1))
    else
      d="$TMP/d1-skip-l6"   # built above: 5-col web-snap row, B5 in sha256 slot
      md1_out="$(bash "$mutant_d1" "$d" 2>&1)"
      if grep -q 'unverifiable-hash' <<<"$md1_out"; then
        printf '  PASS  %-42s (mutant fires misleading hash warn → guard is load-bearing)\n' "teeth: D1 L6-guard mutant → unverifiable-hash"; pass=$((pass+1))
      else
        printf '  FAIL  %-42s (mutant did not produce unverifiable-hash — guard not load-bearing)\n' "teeth: D1 L6-guard"; fail=$((fail+1))
      fi
    fi
  fi

  # D1B teeth: disable the BLOCK-EXIT transition in the pre-check awk (change
  # { in_blk=0 } to { }) so in_blk never resets to 0 after the primary block. The
  # secondary table rows that appear after a heading are then treated as data rows of
  # the primary (registry) block — they get per-row WARNs for their different column
  # count (4 vs 8). The D1-SECOND-TABLE assertion (expects zero WARNs) must fire.
  # bash -n validated first: a syntactically broken mutant cannot prove anything.
  echo "-- teeth proof: D1B — disable BLOCK-EXIT, expect D1-SECOND-TABLE to show false-positive WARNs --"
  mutant_d1b="$TMP/verify-sources.MUTANT-D1B.sh"
  sed 's/{ in_blk=0 }   # BLOCK-EXIT/{ }   # MUTANT-D1B: block-exit disabled/' "$SUT" > "$mutant_d1b"
  if ! grep -q 'MUTANT-D1B' "$mutant_d1b"; then
    echo "  FAIL  could not build D1B mutant (BLOCK-EXIT sentinel not found — did the SUT change?)"; fail=$((fail+1))
  else
    bash -n "$mutant_d1b" 2>/dev/null; d1b_bn=$?
    if [ "$d1b_bn" -ne 0 ]; then
      echo "  FAIL  D1B mutant does not parse (bash -n failed) — control would pass for the wrong reason (THEATER)"; fail=$((fail+1))
    else
      d="$TMP/d1-second-table"   # built above: clean 6-col registry + secondary 2-col table
      md1b_out="$(bash "$mutant_d1b" "$d" 2>&1)"
      if grep -qE 'WARN.*(malformed|schema)' <<<"$md1b_out"; then
        printf '  PASS  %-42s (mutant fires WARN on secondary → BLOCK-EXIT load-bearing)\n' "teeth: D1B BLOCK-EXIT → false-positive WARN"; pass=$((pass+1))
      else
        printf '  FAIL  %-42s (mutant produced no WARN — BLOCK-EXIT not load-bearing)\n' "teeth: D1B BLOCK-EXIT"; fail=$((fail+1))
      fi
    fi
  fi

  # APPENDED-ROWS teeth: revert L6 to the old registry-block scope (awk that reads only
  # rows before the first non-table line) and assert the appended-rows fixture FALSE-PASSES
  # (exit 0). Without the full-file scan, L6 never reaches the appended row's wrong hash.
  # Uses the L6-SCOPE sentinel on the done line. bash -n validated first.
  echo "-- teeth proof: APPENDED-ROWS — revert L6 to registry-block scope, expect appended hash to false-pass --"
  mutant_appended="$TMP/verify-sources.MUTANT-APPENDED.sh"
  _ar_l6ln=$(grep -n 'L6-SCOPE' "$SUT" | head -1 | cut -d: -f1)
  if [ -z "$_ar_l6ln" ]; then
    echo "  FAIL  could not build APPENDED-ROWS mutant (L6-SCOPE sentinel not found — did the SUT change?)"; fail=$((fail+1))
  else
    { head -n $((_ar_l6ln - 1)) "$SUT"
      printf '  done < <(awk '"'"'/^\|/&&/ sha256 /{r=1} r&&/^\|/{print} r&&!/^\|/{r=0}'"'"' "$sources_md" 2>/dev/null)   # MUTANT-APPENDED: reverted to registry-block scope\n'
      tail -n +"$((_ar_l6ln + 1))" "$SUT"
    } > "$mutant_appended"
    if ! grep -q 'MUTANT-APPENDED' "$mutant_appended"; then
      echo "  FAIL  APPENDED-ROWS mutant build failed (replacement not found in output)"; fail=$((fail+1))
    else
      bash -n "$mutant_appended" 2>/dev/null; _mapp_bn=$?
      if [ "$_mapp_bn" -ne 0 ]; then
        echo "  FAIL  APPENDED-ROWS mutant does not parse (bash -n failed) — control would pass for the wrong reason (THEATER)"; fail=$((fail+1))
      else
        d="$TMP/appended-rows-fail"   # built above: appended row has wrong hash, real SUT exits 1
        bash "$mutant_appended" "$d" >/dev/null 2>&1; _mapp_rc=$?
        if [ "$_mapp_rc" = 0 ]; then
          printf '  PASS  %-42s (mutant false-passes → full-file scan is load-bearing)\n' "teeth: APPENDED-ROWS mutant exit 0"; pass=$((pass+1))
        else
          printf '  FAIL  %-42s mutant exit %s (expected 0) — APPENDED-ROWS test may not depend on full-file scan.\n' "teeth: APPENDED-ROWS" "$_mapp_rc"; fail=$((fail+1))
        fi
      fi
    fi
  fi

  # SIGPIPE-RACE teeth: revert count_marker to the old printf|grep pipeline form and
  # assert the large-body fixture produces count=0 (the race fires). With the marker on
  # line 2 and 400KB of filler, grep exits after ~30 bytes, printf gets SIGPIPE (exit 141),
  # set -o pipefail makes the pipeline non-zero, && does not fire, count stays 0 instead of
  # 1. The race is 100% reliable at 400KB (verified on main-branch before the fix).
  # bash -n validated first.
  echo "-- teeth proof: SIGPIPE-RACE — revert count_marker to pipeline form, expect [CERT-doc] count=0 --"
  mutant_sigpipe="$TMP/verify-sources.MUTANT-SIGPIPE.sh"
  _sp_saln=$(grep -n 'SIGPIPE-SAFE' "$SUT" | head -1 | cut -d: -f1)
  if [ -z "$_sp_saln" ]; then
    echo "  FAIL  could not build SIGPIPE mutant (SIGPIPE-SAFE sentinel not found — did the SUT change?)"; fail=$((fail+1))
  else
    { head -n $((_sp_saln - 1)) "$SUT"
      printf '%s\n' '    printf '"'"'%s'"'"' "$body" | grep -qF "$marker" && n=$((n + 1))   # MUTANT-SIGPIPE: pipeline reverted'
      tail -n +"$((_sp_saln + 1))" "$SUT"
    } > "$mutant_sigpipe"
    if ! grep -q 'MUTANT-SIGPIPE' "$mutant_sigpipe"; then
      echo "  FAIL  SIGPIPE mutant build failed (replacement not found in output)"; fail=$((fail+1))
    else
      bash -n "$mutant_sigpipe" 2>/dev/null; _msp_bn=$?
      if [ "$_msp_bn" -ne 0 ]; then
        echo "  FAIL  SIGPIPE mutant does not parse (bash -n failed) — control would pass for the wrong reason (THEATER)"; fail=$((fail+1))
      else
        d="$TMP/sigpipe-det"   # built above: [CERT-doc] on line 2, 400KB filler
        _msp_out="$(bash "$mutant_sigpipe" "$d" 2>&1)"
        _msp_doc="$(printf '%s' "$_msp_out" | grep -oE '\[CERT-doc\] [0-9]+' | grep -oE '[0-9]+')"
        if [ "${_msp_doc:-}" = "0" ]; then
          printf '  PASS  %-42s (pipeline mutant counts 0 → herestring fix is load-bearing)\n' "teeth: SIGPIPE-RACE mutant [CERT-doc]=0"; pass=$((pass+1))
        else
          printf '  FAIL  %-42s (mutant count=%s, expected 0 — race did not trigger or fixture too small)\n' "teeth: SIGPIPE-RACE" "${_msp_doc:-empty}"; fail=$((fail+1))
        fi
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
