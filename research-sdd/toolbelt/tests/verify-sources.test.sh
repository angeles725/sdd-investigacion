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

. "$HERE/lib/mutant.sh"
typeset -f mutant_sed >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_sed ($HERE/lib/mutant.sh)" >&2; exit 2; }
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

# D2-MALFORMED-NOT-COUNTED: a 5-col malformed row for a non-web-snapshot file must NOT
# be counted by the D2 loop even if its shifted cell starts with a hex character.
# TRANE shape: sha256 cell absent, Blocks cell ("B2") shifts into sha256 slot, and "B"
# starts with a hex char (case-insensitive [0-9a-f] matches "B") — without the
# D2-FIELD-GUARD this would count as 1.
d="$TMP/d2-malformed-not-counted"; mkdir -p "$d/sources/docs"
block "$d/d2mn-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — local claim.'
: > "$d/sources/docs/manual.pdf"
{ printf '# Sources\n\n'
  printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| docs/manual.pdf | datasheet | http://x | 2026-01-01 | B2 |\n'
} > "$d/sources/SOURCES.md"     # 5-col: sha256 missing, "B2" shifts into sha256 slot
assert_exit "$SUT" 0 "D2-MALFORMED-NOT-COUNTED: malformed row not counted, exit 0" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'not hash-verified' <<<"$out" \
  && { printf '  FAIL  %-42s (D2 counted the malformed row — D2-FIELD-GUARD missing)\n' "D2-MALFORMED-NOT-COUNTED: no count line"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (malformed row skipped by D2-FIELD-GUARD)\n' "D2-MALFORMED-NOT-COUNTED: no count line"; pass=$((pass+1)); }

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
# L6-FIELD-GUARD ASYMMETRY — the guard is -lt 7 (not -le 7 or -eq 7) on purpose.
# A row with MORE than 7 pipes still has field 6 aligned; skipping it loses coverage.
# A row with FEWER than 7 pipes has genuinely lost its sha256 cell (shifted left).
# These two fixtures pin the two halves of that invariant.

# L6-ASYM-EXTRA-PIPE: a web-snapshot row with 8 pipes (extra pipe inside the Blocks
# cell). Field 6 (sha256) still aligns — the guard must NOT skip this row. The hash
# intentionally mismatches, so the SUT must catch it (exit 1).
d="$TMP/l6-asym-extra-pipe"; mkdir -p "$d/sources/web-snapshots"
block "$d/ae-block1.md" '# Block 1' \
  '## 1.1 cites sources/web-snapshots/extra.md'
snapshot "$d/sources/web-snapshots/extra.md" '<div>extra pipe test — real content here</div>'
_ae_wrong="0000000000000000000000000000000000000000000000000000000000000000"
# Row has 8 pipes: "Blocks" cell contains a literal "|" inside a parenthetical note —
# field 6 (sha256) is still at position 6 and holds the intentionally wrong hash.
{ printf '# External sources preserved\n\n'
  printf '| File | Type | Origin (URL / channel) | Date (UTC) | sha256 | Blocks that cite it |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| web-snapshots/extra.md | web-snapshot | http://x | 2026-01-01 | %s | B1 (see note|p.2) |\n' "$_ae_wrong"
} > "$d/sources/SOURCES.md"
assert_exit "$SUT" 1 "L6-ASYM-EXTRA-PIPE: 8-pipe row caught (hash-mismatch)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'hash-mismatch.*extra\.md' <<<"$out" \
  && { printf '  PASS  %-42s (8-pipe row processed, mismatch reported)\n' "L6-ASYM-EXTRA-PIPE: hash-mismatch line"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (hash-mismatch missing — 8-pipe row skipped by guard?)\n' "L6-ASYM-EXTRA-PIPE: hash-mismatch line"; fail=$((fail+1)); }

# L6-ASYM-FEW-PIPE: a 5-col web-snapshot row (6 pipes). The guard (-lt 7) skips it,
# preventing a misparse where "B1" in the sha256 slot would trigger unverifiable-hash.
# No unverifiable-hash in output; malformed-row WARN IS present from the pre-check awk.
d="$TMP/l6-asym-few-pipe"; mkdir -p "$d/sources"
block "$d/af-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — a local claim.'
{ printf '# Sources\n\n'
  printf '| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| web-snapshots/few.md | web-snapshot | http://x | 2026-01-01 | B1 |\n'
} > "$d/sources/SOURCES.md"     # 5-col: sha256 cell missing, B1 shifts into sha256 slot
snapshot "$d/sources/web-snapshots/few.md" '<div>body</div>'
assert_exit "$SUT" 0 "L6-ASYM-FEW-PIPE: 5-col row, exit 0 (guard skips)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'unverifiable-hash' <<<"$out" \
  && { printf '  FAIL  %-42s (misleading hash WARN from 5-col row — guard not skipping)\n' "L6-ASYM-FEW-PIPE: no unverifiable-hash"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no misleading hash output for 5-col row)\n' "L6-ASYM-FEW-PIPE: no unverifiable-hash"; pass=$((pass+1)); }
grep -qE 'WARN.*malformed' <<<"$out" \
  && { printf '  PASS  %-42s (malformed-row WARN present from pre-check)\n' "L6-ASYM-FEW-PIPE: malformed WARN present"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (malformed WARN missing)\n' "L6-ASYM-FEW-PIPE: malformed WARN present"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# L4-UNPOPULATED-BCELL — §7 anti-silent-zero: SOURCES.md has ≥1 registered row, ALL rows have a
#   blank "Blocks that cite it" cell, AND ≥1 block cites a preserved sources/ path on disk.
#   LEVEL-4 cross-check ran on 0 declared citations despite real block→source cites existing.
#   The script must WARN that fabrication is UNCHECKED. (RED-FIRST: before the fix, this WARN is absent.)
d="$TMP/l4-unpopulated-bcell"; mkdir -p "$d/sources"
block "$d/up-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.pdf §1 — cites a preserved datasheet.'
: > "$d/sources/ds.pdf"
sources_registry "$d" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 |  |'
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*LEVEL-4.*UNCHECKED' <<<"$out" \
  && { printf '  PASS  %-42s (WARN emitted for unpopulated bcell)\n' "L4-UNPOPULATED-BCELL: WARN present"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN absent — §7 silent-disable bug)\n' "L4-UNPOPULATED-BCELL: WARN present"; fail=$((fail+1)); }

# NEGATIVE GUARD: L4-NO-DISK-CITES — SOURCES.md has rows AND blank "Blocks that cite it" cells,
#   but NO block cites any sources/ path on disk → nothing to cross-check → WARN must NOT appear.
#   With the divergence-free probe: "ds.pdf" does not appear in the block body → probe finds
#   no match → no WARN. (Tests the (b) state of the three-state discipline.)
d="$TMP/l4-no-disk-cites"; mkdir -p "$d/sources"
block "$d/nd-block1.md" '# Block 1' '## 1.1 [CERT] file.c:1 — purely local claim, no sources/ reference.'
: > "$d/sources/ds.pdf"
sources_registry "$d" '| ds.pdf | datasheet | http://x | 2026-01-01 | abcd123 |  |'
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*LEVEL-4.*UNCHECKED' <<<"$out" \
  && { printf '  FAIL  %-42s (spurious WARN fired — over-warning)\n' "L4-NO-DISK-CITES: no spurious WARN"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no spurious WARN when no block cites sources)\n' "L4-NO-DISK-CITES: no spurious WARN"; pass=$((pass+1)); }

# L4-NONWHITELIST-EXT — Defect 1: the disk-cite probe must use the same match mechanism as
#   LEVEL-4's positive check. The OLD probe used a grep extension whitelist (.pdf|.md|…) that
#   misses non-whitelisted extensions (.py, .png, .mib, …). A block citing sources/ds.py was
#   invisible to the old probe → no WARN even though blocks cite a preserved source on disk.
#   RED-FIRST: against the pre-fix SUT, the WARN-PRESENT assertion FAILS (WARN absent).
#   After the divergence-free fix it PASSES.
d="$TMP/l4-nonwhitelist-ext"; mkdir -p "$d/sources"
block "$d/nx-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/ds.py §1 — cites a .py source outside the old whitelist.'
: > "$d/sources/ds.py"
sources_registry "$d" '| ds.py | script | http://x | 2026-01-01 | abcd123 |  |'
assert_exit "$SUT" 0 "L4-NONWHITELIST-EXT: exit 0 (WARN, no fail)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'WARN.*LEVEL-4.*UNCHECKED' <<<"$out" \
  && { printf '  PASS  %-42s (WARN emitted for non-whitelist ext cite)\n' "L4-NONWHITELIST-EXT: WARN present"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (WARN absent — non-whitelist ext not probed)\n' "L4-NONWHITELIST-EXT: WARN present"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# 49 — SOURCES.md row scan grep error (exit ≥2, site verify-sources.sh:79) must emit a WARN;
#      never collapse to a confident 0 that passes the "registry unpopulated" check falsely.
#      Stubs grep so the first pipeline call (pattern '^\| ') exits 2 (ENOMEM-class error).
_vs_real_grep=/usr/bin/grep
_stub_vs49="$TMP/stub-bin-vs49"
mkdir -p "$_stub_vs49"
cat > "$_stub_vs49/grep" << STUB_VS49
#!/usr/bin/env bash
[ "\$1" = "-vcE" ] && exit 2
exec "$_vs_real_grep" "\$@"
STUB_VS49
chmod +x "$_stub_vs49/grep"
d_vs49="$TMP/vs49-scan-fail"
sources_registry "$d_vs49" '| doc.pdf | doc | http://x | 2026-01-01 | abc123 |  |'
block "$d_vs49/b1.md" '# Block 1' '[CERT-doc] doc.pdf:1.'
out_vs49="$(PATH="$_stub_vs49:$PATH" bash "$SUT" "$d_vs49" 2>&1)"
grep -qiE 'row scan FAILED|row count unavailable' <<<"$out_vs49" \
  && { printf '  PASS  %-42s (WARN emitted)\n' "49 row-scan grep exit-2 → WARN"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s :: %s\n' "49 row-scan grep exit-2 not reported" "$out_vs49"; fail=$((fail+1)); }

# 50 — T-VS1: .jsonl cited but not on disk → LEVEL 3 must catch it (extract full .jsonl path, not .json).
d_vs1_jsonl="$TMP/vs1-jsonl"; mkdir -p "$d_vs1_jsonl/sources"
block "$d_vs1_jsonl/vs1-block1.md" '# Block 1' 'Evidence at sources/data.jsonl (raw event stream).'
out_vs1_jsonl="$(bash "$SUT" "$d_vs1_jsonl" 2>&1)"; rc_vs1_jsonl=$?
if [ "$rc_vs1_jsonl" = 1 ] && grep -qF 'sources/data.jsonl' <<<"$out_vs1_jsonl"; then
  printf '  PASS  %-42s (exit 1, correct path in output)\n' "50 T-VS1: .jsonl cited-but-missing → LEVEL 3 caught"; pass=$((pass+1))
else
  printf '  FAIL  %-42s :: rc=%s jsonl=%s out=%s\n' "50 T-VS1: .jsonl not caught correctly" "$rc_vs1_jsonl" "$(grep -c 'data.jsonl' <<<"$out_vs1_jsonl")" "$(grep 'sources/' <<<"$out_vs1_jsonl" | head -1)"; fail=$((fail+1))
fi

# 51 — T-VS1: .ndjson cited but not on disk → LEVEL 3 must catch it.
d_vs1_ndjson="$TMP/vs1-ndjson"; mkdir -p "$d_vs1_ndjson/sources"
block "$d_vs1_ndjson/vs1-block1.md" '# Block 1' 'Log data at sources/events.ndjson.'
out_vs1_ndjson="$(bash "$SUT" "$d_vs1_ndjson" 2>&1)"; rc_vs1_ndjson=$?
if [ "$rc_vs1_ndjson" = 1 ] && grep -qF 'sources/events.ndjson' <<<"$out_vs1_ndjson"; then
  printf '  PASS  %-42s (exit 1)\n' "51 T-VS1: .ndjson cited-but-missing → LEVEL 3 caught"; pass=$((pass+1))
else
  printf '  FAIL  %-42s :: rc=%s ndjson=%s\n' "51 T-VS1: .ndjson not caught" "$rc_vs1_ndjson" "$(grep -c 'events.ndjson' <<<"$out_vs1_ndjson")"; fail=$((fail+1))
fi

# 52 — T-VS1: .tar.gz cited but not on disk → LEVEL 3 must catch it.
d_vs1_tgz="$TMP/vs1-tgz"; mkdir -p "$d_vs1_tgz/sources"
block "$d_vs1_tgz/vs1-block1.md" '# Block 1' 'Snapshot at sources/archive.tar.gz.'
out_vs1_tgz="$(bash "$SUT" "$d_vs1_tgz" 2>&1)"; rc_vs1_tgz=$?
if [ "$rc_vs1_tgz" = 1 ] && grep -qF 'sources/archive.tar.gz' <<<"$out_vs1_tgz"; then
  printf '  PASS  %-42s (exit 1)\n' "52 T-VS1: .tar.gz cited-but-missing → LEVEL 3 caught"; pass=$((pass+1))
else
  printf '  FAIL  %-42s :: rc=%s tgz=%s\n' "52 T-VS1: .tar.gz not caught" "$rc_vs1_tgz" "$(grep -c 'archive.tar.gz' <<<"$out_vs1_tgz")"; fail=$((fail+1))
fi

# 53 — T-VS1: .jsonl cited AND exists on disk → LEVEL 3 passes (exit 0, no false-positive).
d_vs1_ok="$TMP/vs1-jsonl-ok"; mkdir -p "$d_vs1_ok/sources"
printf 'data\n' > "$d_vs1_ok/sources/data.jsonl"
block "$d_vs1_ok/vs1-block1.md" '# Block 1' 'Evidence at sources/data.jsonl (raw event stream).'
out_vs1_ok="$(bash "$SUT" "$d_vs1_ok" 2>&1)"; rc_vs1_ok=$?
if [ "$rc_vs1_ok" = 0 ]; then
  printf '  PASS  %-42s (exit 0)\n' "53 T-VS1: .jsonl cited and exists → LEVEL 3 passes"; pass=$((pass+1))
else
  printf '  FAIL  %-42s :: rc=%s %s\n' "53 T-VS1: existing .jsonl falsely failed" "$rc_vs1_ok" "$(grep -iE 'cited-but|missing' <<<"$out_vs1_ok" | head -1)"; fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# #1228 — the File column may carry the repo-root form `sources/web-snapshots/<f>` as well as the bare
# `web-snapshots/<f>` form. Both must register a snapshot (LEVEL 5) AND be hash-verified (LEVEL 6).
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
# one fixture builder: rootform_corpus <dir> <row-prefix-for-a> ; a.md registered with the given File-cell prefix
d="$TMP/rootform-good"; mkdir -p "$d"
block "$d/rf-block1.md" '# Block 1' '## 1.1 [CERT-web] sources/web-snapshots/a.md — cited.'
snapshot "$d/sources/web-snapshots/a.md" '<div>body</div>'
sources_registry "$d" "| sources/web-snapshots/a.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/a.md") | B1 |"
assert_exit "$SUT" 0 "#1228 GOOD: repo-root-form row registers snapshot" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'orphan-snapshot' <<<"$out" \
  && { printf '  FAIL  %-42s (false orphan)\n' "#1228 root-form not an orphan"; fail=$((fail+1)); } \
  || { printf '  PASS  %-42s (no orphan line)\n' "#1228 root-form not an orphan"; pass=$((pass+1)); }
grep -q 'web-snapshot hashes: 1 verified' <<<"$out" \
  && { printf '  PASS  %-42s (L6 reached the row)\n' "#1228 root-form hash is LEVEL-6 verified"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (L6 skipped the row)\n' "#1228 root-form hash is LEVEL-6 verified"; fail=$((fail+1)); }

# TAMPERED root-form row must be CAUGHT as a hash-mismatch (before the fix L6 never looked at it).
d="$TMP/rootform-tampered"; mkdir -p "$d"
block "$d/rt-block1.md" '# Block 1' '## 1.1 [CERT-web] sources/web-snapshots/a.md — cited.'
snapshot "$d/sources/web-snapshots/a.md" '<div>body</div>'
sources_registry "$d" "| sources/web-snapshots/a.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/a.md") | B1 |"
snapshot "$d/sources/web-snapshots/a.md" '<div>TAMPERED after registration</div>'
assert_exit "$SUT" 1 "#1228 BAD: tampered root-form snapshot" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'hash-mismatch: sources/web-snapshots/a.md' <<<"$out" \
  && { printf '  PASS  %-42s (mismatch line printed)\n' "#1228 root-form tamper → hash-mismatch"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (mismatch line missing)\n' "#1228 root-form tamper → hash-mismatch"; fail=$((fail+1)); }

# LIST EDGES — mixed forms, nested path, first/middle/last position; every snapshot is registered → PASS (0).
d="$TMP/rootform-mixed"; mkdir -p "$d"
block "$d/rm-block1.md" '# Block 1' '## 1.1 [CERT-web] sources/web-snapshots/a.md sources/web-snapshots/b.md sources/web-snapshots/ex.com/c.md sources/web-snapshots/d.md'
for f in a.md b.md ex.com/c.md d.md; do snapshot "$d/sources/web-snapshots/$f" "<div>$f</div>"; done
sources_registry "$d" \
  "| web-snapshots/a.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/a.md") | B1 |" \
  "| sources/web-snapshots/b.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/b.md") | B1 |" \
  "| \`sources/web-snapshots/ex.com/c.md\` | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/ex.com/c.md") | B1 |" \
  "| sources/web-snapshots/d.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/d.md") | B1 |"
assert_exit "$SUT" 0 "#1228 GOOD: mixed bare/root forms, first..last" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'web-snapshot hashes: 4 verified' <<<"$out" \
  && { printf '  PASS  %-42s (all 4 verified)\n' "#1228 mixed forms: all four hash-verified"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (%s)\n' "#1228 mixed forms: all four hash-verified" "$(grep 'web-snapshot hashes' <<<"$out")"; fail=$((fail+1)); }

# NO OVER-SUPPRESSION — a real orphan next to root-form rows is STILL caught, and a prefixed-looking
# row that is not anchored at the File-cell start (`foo/sources/web-snapshots/x.md`) registers nothing.
d="$TMP/rootform-orphan"; mkdir -p "$d"
block "$d/ro-block1.md" '# Block 1' '## 1.1 [CERT-web] sources/web-snapshots/a.md sources/web-snapshots/x.md'
snapshot "$d/sources/web-snapshots/a.md" '<div>a</div>'
snapshot "$d/sources/web-snapshots/x.md" '<div>x, registered only under a foreign prefix</div>'
sources_registry "$d" \
  "| sources/web-snapshots/a.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/a.md") | B1 |" \
  "| foo/sources/web-snapshots/x.md | web-snapshot | http://x | 2026-01-01 | abcd1234 | B1 |"
assert_exit "$SUT" 1 "#1228 BAD: foreign-prefix row does not register" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'orphan-snapshot: sources/web-snapshots/x.md' <<<"$out" && ! grep -q 'orphan-snapshot: sources/web-snapshots/a.md' <<<"$out" \
  && { printf '  PASS  %-42s (only x is orphan)\n' "#1228 orphan isolated from root-form row"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (orphan set wrong)\n' "#1228 orphan isolated from root-form row"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# #1483 — non-web-snapshot rows written in the repo-root form `sources/<f>` must reach the D2 "not hash-verified"
# visibility count (COUNT-ONLY: still not hash-verified, so a wrong hash on them stays exit 0 — no calibration
# change to LEVEL 6). LIST EDGES: bare row FIRST, root-form MIDDLE (backticked), root-form LAST; plus a root-form
# web-snapshot row (belongs to LEVEL 6, must NOT be counted) and a foreign-prefix row (must NOT be counted).
d="$TMP/d2-rootform"; mkdir -p "$d/sources/manuals" "$d/sources/web-snapshots"
block "$d/d2r-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/manuals/a.pdf sources/manuals/b.pdf sources/manuals/c.pdf sources/web-snapshots/w.md'
: > "$d/sources/manuals/a.pdf"; : > "$d/sources/manuals/b.pdf"; : > "$d/sources/manuals/c.pdf"
snapshot "$d/sources/web-snapshots/w.md" '<div>w</div>'
sources_registry "$d" \
  "| manuals/a.pdf | manual | http://x | 2026-01-01 | abcdef01… | B1 |" \
  "| \`sources/manuals/b.pdf\` | manual | http://x | 2026-01-01 | abcdef02… | B1 |" \
  "| sources/manuals/c.pdf | manual | http://x | 2026-01-01 | abcdef03… | B1 |" \
  "| sources/web-snapshots/w.md | web-snapshot | http://x | 2026-01-01 | $(sha_of "$d/sources/web-snapshots/w.md") | B1 |" \
  "| foo/sources/manuals/a.pdf | manual | http://x | 2026-01-01 | abcdef04… | B1 |"
assert_exit "$SUT" 0 "#1483 GOOD: root-form non-web rows, exit 0 (count-only)" "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'non-web-snapshot rows with on-disk files and hashes: 3 not hash-verified' <<<"$out" \
  && { printf '  PASS  %-42s (3 counted: bare + 2 root-form)\n' "#1483 root-form non-web rows counted"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (%s)\n' "#1483 root-form non-web rows counted" "$(grep 'not hash-verified' <<<"$out")"; fail=$((fail+1)); }

# Single root-form row ONLY (single-element list): before the fix the count line was absent altogether.
d="$TMP/d2-rootform-single"; mkdir -p "$d/sources/manuals"
block "$d/d2rs-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/manuals/only.pdf'
: > "$d/sources/manuals/only.pdf"
sources_registry "$d" "| sources/manuals/only.pdf | manual | http://x | 2026-01-01 | abcdef01… | B1 |"
out="$(bash "$SUT" "$d" 2>&1)"
grep -q 'hashes: 1 not hash-verified' <<<"$out" \
  && { printf '  PASS  %-42s (single root-form row counted)\n' "#1483 single root-form row counted"; pass=$((pass+1)); } \
  || { printf '  FAIL  %-42s (%s)\n' "#1483 single root-form row counted" "$(grep 'not hash-verified' <<<"$out")"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# #1487 — EMPTY-INPUT DIGEST (LEVEL 7). A registry hash equal to the digest of empty input proves nothing
# (the file was missing/empty when hashed). FAIL (exit 1) with a typed `empty-digest:` finding. Exact-cell
# match only: a longer hex string that merely CONTAINS the digest is a different value and must NOT fire.
E256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
E1=da39a3ee5e6b4b0d3255bfef95601890afd80709
EMD5=d41d8cd98f00b204e9800998ecf8427e
OK_H=abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234
ed_row() { printf '| %s | datasheet | http://x | 2026-01-01 | %s | — |' "$1" "$2"; }
ed_corpus() { # <name> <row...>
  local n="$1"; shift; local d="$TMP/ed-$n"; mkdir -p "$d"
  block "$d/ed-block1.md" '# Block 1' '## 1.1 [CERT] file.c:10 — local claim.'
  sources_registry "$d" "$@"; : > "$d/sources/a.pdf"
}
ed_check() { # <name> <want-rc> <want-count> <label>
  local d="$TMP/ed-$1" out got n
  out="$(bash "$SUT" "$d" 2>&1)"; got=$?
  n="$(grep -c '^   empty-digest:' <<<"$out")"
  if [ "$got" = "$2" ] && [ "$n" = "$3" ]; then
    printf '  PASS  %-42s (exit %s, %s finding(s))\n' "$4" "$got" "$n"; pass=$((pass+1))
  else
    printf '  FAIL  %-42s want exit %s/%s finding(s), got %s/%s\n' "$4" "$2" "$3" "$got" "$n"; fail=$((fail+1))
  fi
}
ed_corpus single "$(ed_row a.pdf "$E256")"
ed_check single 1 1 "#1487 BAD: single row, sha256 empty digest"
ed_corpus first "$(ed_row a.pdf "$E256")" "$(ed_row b.pdf "$OK_H")" "$(ed_row c.pdf "$OK_H")"
ed_check first 1 1 "#1487 BAD: empty digest in FIRST row"
ed_corpus middle "$(ed_row a.pdf "$OK_H")" "$(ed_row b.pdf "$E256")" "$(ed_row c.pdf "$OK_H")"
ed_check middle 1 1 "#1487 BAD: empty digest in MIDDLE row"
ed_corpus last "$(ed_row a.pdf "$OK_H")" "$(ed_row b.pdf "$OK_H")" "$(ed_row c.pdf "$E256")"
ed_check last 1 1 "#1487 BAD: empty digest in LAST row"
ed_corpus sha1 "$(ed_row a.pdf "$E1")"
ed_check sha1 1 1 "#1487 BAD: sha1 empty digest"
ed_corpus md5 "$(ed_row a.pdf "$EMD5")"
ed_check md5 1 1 "#1487 BAD: md5 empty digest"
ed_corpus upper "$(ed_row a.pdf "$(printf '%s' "$E256" | tr 'a-f' 'A-F')")"
ed_check upper 1 1 "#1487 BAD: UPPERCASE empty digest"
ed_corpus tick "$(ed_row a.pdf "\`$E256\`")"
ed_check tick 1 1 "#1487 BAD: backticked empty digest"
ed_corpus elided "$(ed_row a.pdf "e3b0c442…")"
ed_check elided 1 1 "#1487 BAD: elided empty-digest prefix"
ed_corpus two "$(ed_row a.pdf "$E256")" "$(ed_row b.pdf "$E1")"
ed_check two 1 2 "#1487 BAD: two rows -> two findings"
# NEGATIVES — must stay exit 0 / no finding
ed_corpus sub-long "$(ed_row a.pdf "${E256}00")" "$(ed_row b.pdf "ff${E1}")"
ed_check sub-long 0 0 "#1487 GOOD: digest as substring of longer hex"
ed_corpus sub-prefix "$(ed_row a.pdf "e3b0c4…")" "$(ed_row b.pdf "e3b0c44...")"
ed_check sub-prefix 0 0 "#1487 GOOD: short prefix (<8 hex) is no claim"
ed_corpus other-cell "| a.pdf | datasheet | http://x/$E256 | 2026-01-01 | $OK_H | — |"
ed_check other-cell 0 0 "#1487 GOOD: digest inside a longer URL cell"
ed_corpus shifted "| a.pdf | datasheet | $E256 | 2026-01-01 | — |"
ed_check shifted 1 1 "#1487 BAD: shifted-left row (digest not in col 5)"
ed_corpus clean "$(ed_row a.pdf "$OK_H")"
ed_check clean 0 0 "#1487 GOOD: ordinary hash"

# #1500 R3 — a row with NO closing pipe: its last cell is field NF, which a 2..NF-1 scan never visited
# (CLAUDE.md §7 list edges: single / first / middle / last, digest in the LAST cell).
ed_row_np() { printf '| %s | datasheet | http://x | 2026-01-01 | %s' "$1" "$2"; }   # no trailing pipe
ed_corpus np-single "$(ed_row_np a.pdf "$E256")"
ed_check np-single 1 1 "#1500 BAD: pipe-less single row, last-cell digest"
ed_corpus np-first "$(ed_row_np a.pdf "$E256")" "$(ed_row b.pdf "$OK_H")" "$(ed_row c.pdf "$OK_H")"
ed_check np-first 1 1 "#1500 BAD: pipe-less FIRST row, last-cell digest"
ed_corpus np-middle "$(ed_row a.pdf "$OK_H")" "$(ed_row_np b.pdf "$E256")" "$(ed_row c.pdf "$OK_H")"
ed_check np-middle 1 1 "#1500 BAD: pipe-less MIDDLE row, last-cell digest"
ed_corpus np-last "$(ed_row a.pdf "$OK_H")" "$(ed_row b.pdf "$OK_H")" "$(ed_row_np c.pdf "$E256 ")"
ed_check np-last 1 1 "#1500 BAD: pipe-less LAST row, padded last-cell digest"
ed_corpus np-clean "$(ed_row_np a.pdf "$OK_H")"
ed_check np-clean 0 0 "#1500 GOOD: pipe-less row with an ordinary hash"

# #1500 R4 — fail-open: the awk detector must not be able to die or go blind silently. The stub intercepts
# ONLY the LEVEL 7 program (its text carries EMPTY-DIGEST-TABLE); every other awk call runs the real awk.
#   silent: prints nothing, exit 0 (the dialect-mismatch shape); rcfail: real output but exit 3.
_ed_real_awk="$(command -v awk)"
for _ed_mode in silent rcfail; do
  _ed_stub="$TMP/stub-bin-ed-$_ed_mode"; mkdir -p "$_ed_stub"
  case "$_ed_mode" in silent) _ed_act='exit 0';; rcfail) _ed_act='"'"$_ed_real_awk"'" "$@"; exit 3';; esac
  cat > "$_ed_stub/awk" <<STUB_ED
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *EMPTY-DIGEST-TABLE*) $_ed_act;; esac; done
exec "$_ed_real_awk" "\$@"
STUB_ED
  chmod +x "$_ed_stub/awk"
done
ed_degraded() { # <mode> <label> — a failing/blind detector is a typed ERROR + exit 1, never a clean PASS
  local out got
  out="$(PATH="$TMP/stub-bin-ed-$1:$PATH" bash "$SUT" "$TMP/ed-clean" 2>&1)"; got=$?
  if [ "$got" = 1 ] && grep -q 'ERROR: empty-digest scan DEGRADED' <<<"$out"; then
    printf '  PASS  %-42s (exit 1, typed degraded line)\n' "$2"; pass=$((pass+1))
  else
    printf '  FAIL  %-42s want exit 1 + DEGRADED line, got %s\n' "$2" "$got"; fail=$((fail+1))
  fi
}
ed_degraded silent "#1500 BAD: blind detector (no trailer) is degraded"
ed_degraded rcfail "#1500 BAD: detector exit != 0 is degraded"

# ---------------------------------------------------------------------------
# #1608 — a File cell that is NOT the verbatim in-block token (prose prefix, a literal "(not committed)",
# a parenthetical annotation " (...)") can never match the block text, so LEVEL 4 misjudges it. A bare spaced
# path is verbatim and must NOT warn (its blank-strip is #1678). WARN-only: the
# finding itself never changes the exit code (the exit code below is whatever LEVEL 4 decides for the row).
# Only rows that NAME a block are cross-check candidates; a prose cell with an empty cite cell is not flagged.
nv_corpus() { # <name> <row...> — a corpus whose B1 exists and cites x.jar; B9 deliberately does not resolve
  local d="$TMP/$1"; shift; mkdir -p "$d"
  block "$d/nv-block1.md" '# Block 1' '## 1.1 [CERT-doc] sources/x.jar cited here.'
  sources_registry "$d" "$@"
}
nv_row() { printf '| %s | jar | http://x | 2026-01-01 | abcd1234 | %s |' "$1" "$2"; }
nv_check() { # <name> <want-warn 0|1> <want-rc> <label>
  local out got n=0
  out="$(bash "$SUT" "$TMP/$1" 2>&1)"; got=$?
  grep -qF 'is not a verbatim in-block token' <<<"$out" && n=1
  if [ "$got" = "$3" ] && [ "$n" = "$2" ]; then
    printf '  PASS  %-42s (exit %s, warn=%s)\n' "$4" "$got" "$n"; pass=$((pass+1))
  else
    printf '  FAIL  %-42s want exit %s warn=%s, got exit %s warn=%s\n' "$4" "$3" "$2" "$got" "$n"; fail=$((fail+1))
  fi
}
nv_corpus nv-whole "$(nv_row '(not committed)' B9)"
nv_check nv-whole 1 0 "#1608 BAD: File cell is literally (not committed)"
nv_corpus nv-nc-prefix "$(nv_row '(not committed) x.jar' B9)"
nv_check nv-nc-prefix 1 0 "#1608 BAD: (not committed) prefix on a name"
nv_corpus nv-prose "$(nv_row 'x.jar (build reference)' B9)"
nv_check nv-prose 1 0 "#1608 BAD: parenthetical annotation on a name"
nv_corpus nv-spaced "$(nv_row 'sub dir/My File - 95-7756.pdf' B9)"
nv_check nv-spaced 0 0 "#1608 GOOD: verbatim spaced path (not flagged)"
nv_corpus nv-plus "$(nv_row 'a/x.jar + b/y.jar' B9)"
nv_check nv-plus 0 0 "#1608 GOOD: bare A + B cell (no paren, not flagged)"
nv_corpus nv-paren "$(nv_row '(gone)x.jar' B9)"
nv_check nv-paren 1 0 "#1608 BAD: parenthesised prefix, no blank"
nv_corpus nv-ok "$(nv_row 'x.jar' B9)"
nv_check nv-ok 0 0 "#1608 GOOD: verbatim File cell"
nv_corpus nv-ok-bt "$(nv_row '`x.jar`' B9)"
nv_check nv-ok-bt 0 0 "#1608 GOOD: backticked verbatim File cell"
nv_corpus nv-ok-pad "$(nv_row '   x.jar   ' B9)"
nv_check nv-ok-pad 0 0 "#1608 GOOD: blank-padded verbatim File cell"
nv_corpus nv-nocite "$(nv_row '(not committed) x.jar' '—')"
nv_check nv-nocite 0 0 "#1608 GOOD: prose cell, no block named (not checked)"
nv_corpus nv-first "$(nv_row '(not committed) a.jar' B9)" "$(nv_row 'b.jar' B9)" "$(nv_row 'c.jar' B9)"
nv_check nv-first 1 0 "#1608 BAD: non-verbatim cell in FIRST row"
nv_corpus nv-last "$(nv_row 'a.jar' B9)" "$(nv_row 'b.jar' B9)" "$(nv_row '(not committed)' B9)"
nv_check nv-last 1 0 "#1608 BAD: non-verbatim cell in LAST row"
nv_corpus nv-fab "$(nv_row '(not committed) x.jar' B1)"
nv_check nv-fab 1 1 "#1608 BAD: prose cell also fails LEVEL 4 (WARN + exit 1)"
nv_corpus nv-fab-ok "$(nv_row 'x.jar' B1)"
nv_check nv-fab-ok 0 0 "#1608 GOOD: verbatim cell, real citation"

# #1678 — LEVEL 4 must keep INTERNAL blanks of the File cell (only leading/trailing blanks are padding), so a
# verbatim spaced filename cross-checks against the block text instead of a false FABRICATED-CITE. Edges:
# the spaced row FIRST / MIDDLE / LAST in the table and as the SINGLE row; a genuinely uncited spaced name and
# a block that only carries the blank-collapsed form must still FAIL (the fix must not blunt the check).
sp_corpus() { # <name> <row...> — B1 cites the spaced names verbatim; B2 carries only a blank-collapsed one
  local d="$TMP/$1"; shift; mkdir -p "$d"
  block "$d/sp-block1.md" '# Block 1' \
    '## 1.1 [CERT-doc] Datasheet "IO-16-H InputOutput Module Install - 95-7756.pdf" read.' \
    '## 1.2 [CERT-doc] Also sub dir/My File.pdf and /mnt/c/Program Files/x y.txt.' \
    '## 1.3 [CERT-doc] plain.jar too.'
  block "$d/sp-block2.md" '# Block 2' '## 2.1 [CERT-doc] only MyFile.pdf (collapsed) appears here.'
  sources_registry "$d" "$@"
}
sp_row() { printf '| %s | doc | http://x | 2026-01-01 | abcd1234 | %s |' "$1" "$2"; }
sp_check() { # <name> <want-fab 0|1> <want-rc> <label>
  local out got n=0
  out="$(bash "$SUT" "$TMP/$1" 2>&1)"; got=$?
  grep -qF 'FABRICATED-CITE' <<<"$out" && n=1
  if [ "$got" = "$3" ] && [ "$n" = "$2" ]; then
    printf '  PASS  %-42s (exit %s, fabricated=%s)\n' "$4" "$got" "$n"; pass=$((pass+1))
  else
    printf '  FAIL  %-42s want exit %s fabricated=%s, got exit %s fabricated=%s\n' "$4" "$3" "$2" "$got" "$n"; fail=$((fail+1))
  fi
}
SP_A='IO-16-H InputOutput Module Install - 95-7756.pdf'
sp_corpus sp-single "$(sp_row "$SP_A" B1)"
sp_check sp-single 0 0 "#1678 GOOD: spaced name, single-row table"
sp_corpus sp-first "$(sp_row 'sub dir/My File.pdf' B1)" "$(sp_row 'plain.jar' B1)" "$(sp_row "$SP_A" B1)"
sp_check sp-first 0 0 "#1678 GOOD: spaced name in FIRST row"
sp_corpus sp-mid "$(sp_row 'plain.jar' B1)" "$(sp_row "$SP_A" B1)" "$(sp_row 'sub dir/My File.pdf' B1)"
sp_check sp-mid 0 0 "#1678 GOOD: spaced name in MIDDLE row"
sp_corpus sp-last "$(sp_row 'plain.jar' B1)" "$(sp_row 'sub dir/My File.pdf' B1)" "$(sp_row '/mnt/c/Program Files/x y.txt' B1)"
sp_check sp-last 0 0 "#1678 GOOD: spaced name in LAST row"
sp_corpus sp-pad "$(sp_row "   $SP_A   " B1)"
sp_check sp-pad 0 0 "#1678 GOOD: blank-padded spaced name"
sp_corpus sp-tab "$(printf '|\t%s\t| doc | http://x | 2026-01-01 | abcd1234 | B1 |' "$SP_A")"
sp_check sp-tab 0 0 "#1678 GOOD: tab-padded spaced name"
sp_corpus sp-bt "$(sp_row "\`$SP_A\`" B1)"
sp_check sp-bt 0 0 "#1678 GOOD: backticked spaced name"
sp_corpus sp-uncited "$(sp_row 'Never Cited File.pdf' B1)"
sp_check sp-uncited 1 1 "#1678 BAD: spaced name no block mentions"
sp_corpus sp-uncited-last "$(sp_row "$SP_A" B1)" "$(sp_row 'Never Cited File.pdf' B1)"
sp_check sp-uncited-last 1 1 "#1678 BAD: uncited spaced name in LAST row"
sp_corpus sp-collapsed "$(sp_row 'My File.pdf' B2)"
sp_check sp-collapsed 1 1 "#1678 BAD: block only has the blank-collapsed form"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL — every tooth builds its mutant with lib/mutant.sh (a COPY in $TMP/mutants, never
# the live tree) and asserts the EXACT verdict of the real SUT AND of the mutant on the same fixture.
# mutant_sed refuses an empty / byte-identical / syntax-broken / live-tree mutant (rc 3/4/5/8), so a
# crash or a sed that never applied can never read as teeth. kit issue #1299.
if [ "${1:-}" = "--prove-teeth" ]; then
  mkdir -p "$TMP/mutants"
  # Shared helpers (lib/mutant.sh, #1299) print their own FAIL/PASS line and return non-zero on
  # failure; these adapters only COUNT. Each tooth asserts the EXACT rc (and output patterns) of the
  # real SUT and of the mutant on the same fixture.
  mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain "$l" "$SUT" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
  tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # Multi-line / quote-bearing replacements are sed scripts held in variables (one -e stage each).
  APPENDED_SED="$(cat <<'SED'
/L6-SCOPE/c\
  done < <(awk '/^\\|/&&/ sha256 /{r=1} r&&/^\\|/{print} r&&!/^\\|/{r=0}' "$sources_md" 2>/dev/null)
SED
)"
  SIGPIPE_SED="$(cat <<'SED'
/&& n=\$((n + 1)) *# SIGPIPE-SAFE/c\
    printf '%s' "$body" | grep -qF "$marker" && n=$((n + 1))  # sigpipe-lint: allow SIGPIPE_SED mutant text that restores the piped idiom
SED
)"
  # Shape: mk_sed ID MUTANT EXPR... && tooth "teeth ID: label" GOOD_RC BAD_RC MUTANT [patterns] -- bash @SUT@ FIXTURE
  m="$TMP/mutants/RESOLUTION.sh"
  mk_sed RESOLUTION "$m" 's|corpus="$(dirname "$anchor")"|corpus="$target"|' \
    && tooth "teeth RESOLUTION: corpus-root resolution reverted to \$target" 1 0 "$m" -- bash @SUT@ "$TMP/flagship-subdir"
  m="$TMP/mutants/L5-SUBSTRING.sh"
  mk_sed L5-SUBSTRING "$m" '/grep -qxF "$rel" <<< "$registered"/c\  if ! grep -qF "$(basename "$rel")" <<< "$registered"; then' \
    && tooth "teeth L5-SUBSTRING: exact registration match reverted to basename substring" 1 0 "$m" -- bash @SUT@ "$TMP/bad-substring-collision"
  m="$TMP/mutants/FIXA-TAB.sh"
  mk_sed FIXA-TAB "$m" 's|gsub(/\[`\[:blank:\]\]/|gsub(/[` ]/|' \
    && tooth "teeth FIXA-TAB: tab-trim normalization dropped" 0 1 "$m" -- bash @SUT@ "$TMP/good-tab-padded-registration"
  m="$TMP/mutants/L6-COMPARE.sh"
  mk_sed L6-COMPARE "$m" '/HASH-INTEGRITY compare/c\      if false; then' \
    && tooth "teeth L6-COMPARE: hash compare neutralized" 1 0 "$m" -- bash @SUT@ "$TMP/bad-hash-mismatch"
  m="$TMP/mutants/L1-LEGEND.sh"
  mk_sed L1-LEGEND "$m" '/LEGEND-STRIP: count markers/c\      body="$(cat "$f")"' \
    && tooth "teeth L1-LEGEND: legend strip reverted (whole file counted)" 0 1 "$m" -- bash @SUT@ "$TMP/legend-only-no-registry"
  m="$TMP/mutants/B4-CITED.sh"
  mk_sed B4-CITED "$m" 's/_cited_ok=0$/_cited_ok=1/' \
    && tooth "teeth B4-CITED: citation check disabled (_cited_ok preset)" 1 0 "$m" -- bash @SUT@ "$TMP/b4-multi-focus-bad"
  m="$TMP/mutants/PFX.sh"
  mk_sed PFX "$m" '/PREFIX-COMPARISON compare/c\            disk_pfx="$pfx_lower"' \
    && tooth "teeth PFX: prefix comparison neutralized" 1 0 "$m" -- bash @SUT@ "$TMP/bad-prefix-mismatch"
  # D1: anchor on the CODE line only. The old awk matched /L6-FIELD-GUARD/ anywhere and so ALSO
  # overwrote the explanatory comment at verify-sources.sh:303 with executable code (defect).
  m="$TMP/mutants/D1-GUARD.sh"
  mk_sed D1-GUARD "$m" '/pipes=.*# L6-FIELD-GUARD$/c\  pipes="${_raw//[^|]/}"; [ 1 -ne 1 ] && continue' \
    && tooth "teeth D1-GUARD: L6 field guard disabled" 0 0 "$m" --good-lacks 'unverifiable-hash' --bad-has 'unverifiable-hash' -- bash @SUT@ "$TMP/d1-skip-l6"
  m="$TMP/mutants/D1B-BLOCKEXIT.sh"
  mk_sed D1B-BLOCKEXIT "$m" 's/{ in_blk=0 }   # BLOCK-EXIT/{ }/' \
    && tooth "teeth D1B-BLOCKEXIT: registry block-exit disabled" 0 0 "$m" --good-lacks 'WARN.*(malformed|schema)' --bad-has 'WARN.*(malformed|schema)' -- bash @SUT@ "$TMP/d1-second-table"
  m="$TMP/mutants/APPENDED.sh"
  mk_sed APPENDED "$m" "$APPENDED_SED" \
    && tooth "teeth APPENDED: L6 reverted to registry-block scope" 1 0 "$m" -- bash @SUT@ "$TMP/appended-rows-fail"
  m="$TMP/mutants/SIGPIPE.sh"
  mk_sed SIGPIPE "$m" "$SIGPIPE_SED" \
    && tooth "teeth SIGPIPE: count_marker reverted to printf|grep pipeline" 0 0 "$m" \
         --good-has '\[CERT-doc\] 1([^0-9]|$)' --bad-has '\[CERT-doc\] 0([^0-9]|$)' --bad-lacks '\[CERT-doc\] [1-9]' -- bash @SUT@ "$TMP/sigpipe-det"
  m="$TMP/mutants/L4SZ.sh"
  mk_sed L4SZ "$m" '/L4-SILENT-ZERO-GUARD/c\  if false; then' \
    && tooth "teeth L4SZ: L4 silent-zero guard neutralized" 0 0 "$m" --good-has 'WARN.*LEVEL-4.*UNCHECKED' --bad-lacks 'WARN.*LEVEL-4.*UNCHECKED' -- bash @SUT@ "$TMP/l4-unpopulated-bcell"
  m="$TMP/mutants/L4PROBE.sh"
  mk_sed L4PROBE "$m" '/L4-PROBE-MATCH/c\        if false; then' \
    && tooth "teeth L4PROBE: L4 probe neutralized" 0 0 "$m" --good-has 'WARN.*LEVEL-4.*UNCHECKED' --bad-lacks 'WARN.*LEVEL-4.*UNCHECKED' -- bash @SUT@ "$TMP/l4-nonwhitelist-ext"
  m="$TMP/mutants/L6ASYM.sh"
  mk_sed L6ASYM "$m" '/pipes=.*# L6-FIELD-GUARD$/s/-lt 7/-ne 7/' \
    && tooth "teeth L6ASYM: L6 guard -lt 7 changed to -ne 7" 1 0 "$m" -- bash @SUT@ "$TMP/l6-asym-extra-pipe"
  m="$TMP/mutants/VS1-REGEX.sh"
  mk_sed VS1-REGEX "$m" 's/(jsonl|ndjson|gz|/(/' \
    && tooth "teeth VS1-REGEX: LEVEL 3 regex drops jsonl|ndjson|gz" 1 0 "$m" -- bash @SUT@ "$d_vs1_ndjson"
  m="$TMP/mutants/SRCPFX-L5.sh"
  mk_sed SRCPFX-L5 "$m" '/SRCPFX-L5/d' \
    && tooth "teeth SRCPFX-L5: LEVEL 5 root-form normalization dropped" 0 1 "$m" -- bash @SUT@ "$TMP/rootform-good"
  m="$TMP/mutants/SRCPFX-L6.sh"
  mk_sed SRCPFX-L6 "$m" '/SRCPFX-L6/d' \
    && tooth "teeth SRCPFX-L6: LEVEL 6 root-form normalization dropped" 1 0 "$m" -- bash @SUT@ "$TMP/rootform-tampered"
  m="$TMP/mutants/SRCPFX-D2.sh"
  mk_sed SRCPFX-D2 "$m" '/SRCPFX-D2/d' \
    && tooth "teeth SRCPFX-D2: D2 root-form normalization dropped" 0 0 "$m" --good-has 'hashes: 3 not hash-verified' --bad-lacks 'hashes: 3 not hash-verified' -- bash @SUT@ "$TMP/d2-rootform"
  m="$TMP/mutants/VS49-RC.sh"
  mk_sed VS49-RC "$m" 's/_vsrc_rows_rc=$?/_vsrc_rows_rc=0/' \
    && MUTANT_TOOTH_ICASE=1 tooth "teeth VS49-RC: row-scan rc zeroed" 0 0 "$m" \
         --good-has 'row scan FAILED|row count unavailable' --bad-lacks 'row scan FAILED|row count unavailable' \
         -- env PATH="$_stub_vs49:$PATH" bash @SUT@ "$d_vs49"
  # #1487 LEVEL 7 teeth: the detector disabled, the exact match widened to substring, the prefix arm dropped,
  # the md5 table entry removed (ED-NOMD5), the scan narrowed to column 5 (ED-COL5) and the minimum-prefix
  # length check dropped (ED-NOMINP) must each flip the verdict on the matching fixture.
  m="$TMP/mutants/ED-OFF.sh"
  mk_sed ED-OFF "$m" '/# EMPTY-DIGEST-MATCH$/s/if (.*) {/if (0) {/' \
    && tooth "teeth ED-OFF: empty-digest match disabled" 1 0 "$m" --good-has 'empty-digest:' --bad-lacks 'empty-digest:' -- bash @SUT@ "$TMP/ed-single"
  m="$TMP/mutants/ED-SUBSTR.sh"
  mk_sed ED-SUBSTR "$m" '/# EMPTY-DIGEST-MATCH$/s/p == d\[k\]/index(p, d[k]) > 0/' \
    && tooth "teeth ED-SUBSTR: exact match widened to substring" 0 1 "$m" --bad-has 'empty-digest:' -- bash @SUT@ "$TMP/ed-sub-long"
  m="$TMP/mutants/ED-NOPFX.sh"
  mk_sed ED-NOPFX "$m" '/# EMPTY-DIGEST-MATCH$/s/ || (el .*index(d\[k\], p) == 1)//' \
    && tooth "teeth ED-NOPFX: elided-prefix arm dropped" 1 0 "$m" --good-has 'empty-digest:' --bad-lacks 'empty-digest:' -- bash @SUT@ "$TMP/ed-elided"
  m="$TMP/mutants/ED-NOMD5.sh"
  mk_sed ED-NOMD5 "$m" '/d\["md5"\]=/s/d41d8cd98f00b204e9800998ecf8427e/00000000000000000000000000000000/' \
    && tooth "teeth ED-NOMD5: md5 digest dropped from the table" 1 0 "$m" --good-has 'empty-digest:' --bad-lacks 'empty-digest:' -- bash @SUT@ "$TMP/ed-md5"
  m="$TMP/mutants/ED-NOMINP.sh"
  mk_sed ED-NOMINP "$m" '/# EMPTY-DIGEST-MATCH$/s/length(p) >= minp \&\& //' \
    && tooth "teeth ED-NOMINP: minimum-prefix length check dropped" 0 1 "$m" --bad-has 'empty-digest:' -- bash @SUT@ "$TMP/ed-sub-prefix"
  m="$TMP/mutants/ED-COL5.sh"
  mk_sed ED-COL5 "$m" 's/for (i = 2; i <= NF; i++) {/for (i = 6; i < 7; i++) {/' \
    && tooth "teeth ED-COL5: scan narrowed to the sha256 column only" 1 0 "$m" --good-has 'empty-digest:' --bad-lacks 'empty-digest:' -- bash @SUT@ "$TMP/ed-shifted"
  m="$TMP/mutants/ED-PIPELESS.sh"
  mk_sed ED-PIPELESS "$m" 's/for (i = 2; i <= NF; i++) {/for (i = 2; i < NF; i++) {/' \
    && tooth "teeth ED-PIPELESS: last cell skipped again" 1 0 "$m" --good-has 'empty-digest:' --bad-lacks 'empty-digest:' -- bash @SUT@ "$TMP/ed-np-single"
  m="$TMP/mutants/ED-NORC.sh"
  mk_sed ED-NORC "$m" 's/_ed_rc=$?/_ed_rc=0/' \
    && tooth "teeth ED-NORC: detector rc ignored" 1 0 "$m" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-ed-rcfail:$PATH" bash @SUT@ "$TMP/ed-clean"
  m="$TMP/mutants/ED-NOTRAILER.sh"
  mk_sed ED-NOTRAILER "$m" 's/ || \[ -n "\$_ed_trailer" \]; then/; then/' \
    && tooth "teeth ED-NOTRAILER: missing coverage trailer ignored" 1 0 "$m" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-ed-silent:$PATH" bash @SUT@ "$TMP/ed-clean"
  # #1608 — non-verbatim File cell WARN. Every tooth keeps both rc at 0 and discriminates on the typed line.
  NV_ERR='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError'
  m="$TMP/mutants/NV-OFF.sh"
  mk_sed NV-OFF "$m" "/# NONVERBATIM-FILE-CELL\$/s/case \"\\\$_nv_cell\" in/case \"x\" in/" \
    && tooth "teeth NV-OFF: non-verbatim cell check disabled" 0 0 "$m" --good-has 'is not a verbatim in-block token' --bad-lacks "is not a verbatim in-block token|$NV_ERR" -- bash @SUT@ "$TMP/nv-prose"
  m="$TMP/mutants/NV-NOLEAD.sh"
  mk_sed NV-NOLEAD "$m" "s/^      '('\\*|\\*\\[\\[:blank:\\]\\]'('\\*)\$/      *[[:blank:]]'('*)/" \
    && tooth "teeth NV-NOLEAD: leading-paren arm dropped" 0 0 "$m" --good-has 'is not a verbatim in-block token' --bad-lacks "is not a verbatim in-block token|$NV_ERR" -- bash @SUT@ "$TMP/nv-paren"
  m="$TMP/mutants/NV-NOANNOT.sh"
  mk_sed NV-NOANNOT "$m" "s/^      '('\\*|\\*\\[\\[:blank:\\]\\]'('\\*)\$/      '('*)/" \
    && tooth "teeth NV-NOANNOT: parenthetical-annotation arm dropped" 0 0 "$m" --good-has 'is not a verbatim in-block token' --bad-lacks "is not a verbatim in-block token|$NV_ERR" -- bash @SUT@ "$TMP/nv-prose"
  m="$TMP/mutants/NV-NOCITEGATE.sh"
  mk_sed NV-NOCITEGATE "$m" "s/^        if grep -qiE '.bB(lock|loque)? ?\\[0-9\\]+' <<< \"\\\$(printf '%s' \"\\\$bcell\" | sed 's\\/(\\[^)\\]\\*)\\/\\/g')\"; then\$/        if true; then/" \
    && tooth "teeth NV-NOCITEGATE: flags rows that name no block" 0 0 "$m" --good-lacks 'is not a verbatim in-block token' --bad-has 'is not a verbatim in-block token' -- bash @SUT@ "$TMP/nv-nocite"
  # #1678 — LEVEL 4 File-cell trim. Both teeth need exact rc on the real SUT and the mutant plus a typed line.
  m="$TMP/mutants/SP-STRIPALL.sh"
  mk_sed SP-STRIPALL "$m" '/# L4-FILE-TRIM$/s#.*#    file="${file//[[:blank:]]/}"#' \
    && tooth "teeth SP-STRIPALL: all blanks stripped again" 0 1 "$m" --good-lacks 'FABRICATED-CITE' --bad-has 'FABRICATED-CITE' --bad-lacks "$NV_ERR" -- bash @SUT@ "$TMP/sp-single"
  m="$TMP/mutants/SP-NOTRIM.sh"
  mk_sed SP-NOTRIM "$m" '/# L4-FILE-TRIM$/s#.*#    :#' \
    && tooth "teeth SP-NOTRIM: padding no longer trimmed" 0 1 "$m" --good-lacks 'FABRICATED-CITE' --bad-has 'FABRICATED-CITE' --bad-lacks "$NV_ERR" -- bash @SUT@ "$TMP/sp-pad"
  m="$TMP/mutants/SP-TABKEEP.sh"
  mk_sed SP-TABKEEP "$m" '/# L4-FILE-TRIM$/s#\[!\[:blank:\]\]#[! ]#g' \
    && tooth "teeth SP-TABKEEP: tab padding no longer trimmed" 0 1 "$m" --good-lacks 'FABRICATED-CITE' --bad-has 'FABRICATED-CITE' --bad-lacks "$NV_ERR" -- bash @SUT@ "$TMP/sp-tab"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
