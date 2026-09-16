#!/usr/bin/env bash
# Guard suite: committed fixture files must not be modified by test-suite runs.
# Each affected suite (niagara-security-audit, module-find, corroborate-ifc)
# must generate transient fixtures into a tmpdir, never into tests/fixtures/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# MAJOR-2: if not inside a git work-tree, this guard cannot function.
# A missing git context must be an operational failure (exit 2), never a pass.
# ---------------------------------------------------------------------------
git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "FATAL: not inside a git work-tree; guard requires git" >&2; exit 2; }

REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
COMMITTED_DIR="$HERE/fixtures"

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# T1: running the real test suites must not dirty the committed fixture tree.
# Before/after snapshot pattern:
#   1. Capture git status BEFORE running suites.
#   2. Run niagara-security-audit, module-find, corroborate-ifc.
#   3. Capture git status AFTER.
#   4. FAIL only if NEW dirt appeared (lines in after not in before).
#      Pre-existing dev modifications are excluded (they appear in both snapshots).
# ---------------------------------------------------------------------------

# Snapshot before — must not fail
_before="$(git -C "$REPO_ROOT" status --porcelain -- "$COMMITTED_DIR" 2>&1)" \
  || { echo "FATAL: git status (before) failed" >&2; exit 2; }
# Filter staged deletions ('^D ') — legitimately staged when old fixture files
# are removed as part of this fix's PR; becomes a no-op after this is merged.
_before_filtered="$(printf '%s\n' "$_before" | grep -v '^D ')"

# Run the real suites; we do not care if they pass or fail — only about git state.
bash "$HERE/niagara-security-audit.test.sh"  >/dev/null 2>&1 || true
bash "$HERE/module-find.test.sh"             >/dev/null 2>&1 || true
bash "$HERE/corroborate-ifc.test.sh"         >/dev/null 2>&1 || true

# Snapshot after — must not fail
_after="$(git -C "$REPO_ROOT" status --porcelain -- "$COMMITTED_DIR" 2>&1)" \
  || { echo "FATAL: git status (after) failed" >&2; exit 2; }
_after_filtered="$(printf '%s\n' "$_after" | grep -v '^D ')"

# New dirt = lines present in after but absent in before.
# Using sorted comm: any line unique to _after_filtered is run-induced dirt.
_new_dirt="$(comm -13 \
  <(printf '%s\n' "$_before_filtered" | grep -v '^$' | sort) \
  <(printf '%s\n' "$_after_filtered"  | grep -v '^$' | sort) \
  2>/dev/null || true)"

if [ -z "$_new_dirt" ]; then
  ok "T1 real suites do not dirty committed fixture tree"
else
  no "T1 real suites dirtied committed fixture tree: $_new_dirt"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: hermetic-fixtures guard --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

# M1: mutant of niagara-security-audit.test.sh where FX is reverted from
# the tmpdir back to the committed fixture path.
# Strategy: copy the real suite to a temp dir, sed-mutate the copy, run it.
# Never mutate the live suite file. Trap cleans up both MUTDIR and any written
# committed-tree files that the mutant run may have created.
# Place MUTDIR inside the toolbelt directory (sibling of tests/) so that
# $HERE/../niagara-security-audit.sh in the mutant resolves to the real SUT.
MUTDIR="$(mktemp -d -p "$(cd "$HERE/.." && pwd)")"
_m1_cleanup() {
  rm -rf "$MUTDIR"
  # Remove any untracked files the mutant wrote (all niagara-security-audit fixtures
  # were git-rm'd so any file there is untracked and safe to clean).
  git -C "$REPO_ROOT" clean -fd -- "$COMMITTED_DIR/niagara-security-audit/" 2>/dev/null || true
  # Restore any tracked files the mutant may have modified (belt-and-suspenders).
  git -C "$REPO_ROOT" checkout -- "$COMMITTED_DIR/niagara-security-audit/" 2>/dev/null || true
}
trap '_m1_cleanup' EXIT

cp "$HERE/niagara-security-audit.test.sh" "$MUTDIR/niagara-security-audit.test.sh"

# Revert FX="$ROOT/fixtures" to the committed path so the mutant writes there.
# Also remove the FX-under-ROOT guard so the mutant does not exit 2 before
# generating fixtures. Both together simulate a real regression (FX reverted,
# guard removed) — the committed tree now receives the generated files.
_committed_nia="$COMMITTED_DIR/niagara-security-audit"
sed -i 's|FX="\$ROOT/fixtures"|FX="'"$_committed_nia"'"|g' \
  "$MUTDIR/niagara-security-audit.test.sh"
sed -i '/^# Guard: FX must be under ROOT/,/^esac$/d' \
  "$MUTDIR/niagara-security-audit.test.sh"

if cmp -s "$HERE/niagara-security-audit.test.sh" "$MUTDIR/niagara-security-audit.test.sh"; then
  mut_no "M1 mutant setup: sed had no effect — FX pattern not found in suite"
else
  # Run the mutant; expect it to write into the committed tree
  bash "$MUTDIR/niagara-security-audit.test.sh" >/dev/null 2>&1 || true

  # Check for new dirt relative to the before-snapshot
  _mut_after="$(git -C "$REPO_ROOT" status --porcelain -- "$COMMITTED_DIR" 2>&1)" \
    || { mut_no "M1 git status failed after mutant run"; rm -rf "$MUTDIR"; }

  _mut_after_filtered="$(printf '%s\n' "$_mut_after" | grep -v '^D ')"
  _mut_new_dirt="$(comm -13 \
    <(printf '%s\n' "$_before_filtered" | grep -v '^$' | sort) \
    <(printf '%s\n' "$_mut_after_filtered" | grep -v '^$' | sort) \
    2>/dev/null || true)"

  # Restore committed tree immediately (before final verdict)
  git -C "$REPO_ROOT" checkout -- "$COMMITTED_DIR/niagara-security-audit/" 2>/dev/null || true

  if [ -n "$_mut_new_dirt" ]; then
    mut_ok "M1 mutant FX→committed-path: guard detects dirty committed tree — has teeth"
  else
    mut_no "M1 mutant FX→committed-path: no new dirt detected — guard is blind"
  fi
fi

rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
