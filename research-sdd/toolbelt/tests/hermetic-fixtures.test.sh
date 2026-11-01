#!/usr/bin/env bash
# Guard suite: committed fixture files must not be modified by test-suite runs.
# Each affected suite (module-find, corroborate-ifc) must generate transient
# fixtures into a tmpdir, never into tests/fixtures/. niagara-security-audit was
# one of them until its bash suite was replaced by Go tests (kit issue #2405),
# which never write under tests/fixtures/.
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
#   2. Run module-find, corroborate-ifc.
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

# M1: a fixture-generating script that writes into the committed tree, the regression the guard exists
# to catch. It is synthetic on purpose: the guard's verdict is "new dirt between two snapshots", and a
# probe that depends on no live suite survives those suites being ported or deleted (the earlier M1
# mutated niagara-security-audit.test.sh, deleted by kit issue #2405). Trap cleans up the probe dir.
MUTDIR="$(mktemp -d)"
_probe="$COMMITTED_DIR/hermetic-fixtures-probe"
_probe_ours=0  # set only once this run has created the probe: a pre-existing path is never removed
_m1_cleanup() {
  rm -rf "$MUTDIR"
  [ "$_probe_ours" -eq 1 ] && rm -rf "$_probe"
  return 0
}
trap '_m1_cleanup' EXIT
if [ -e "$_probe" ]; then
  mut_no "M1 probe path already exists (stale run?): $_probe"
else
  cat >"$MUTDIR/leaky-suite.sh" <<'LEAK'
#!/usr/bin/env bash
# Writes its generated fixture into the committed fixture tree instead of a tmpdir.
set -eu
mkdir -p "$1"
printf 'generated\n' >"$1/generated.txt"
echo "== 1 passed · 0 failed =="
LEAK
  _probe_ours=1
  _m1_out="$(bash "$MUTDIR/leaky-suite.sh" "$_probe" 2>&1 || true)"
  if ! grep -Eq '^== [0-9]+ passed' <<<"$_m1_out"; then
    mut_no "M1 probe did not run to its summary line: $(tail -n 3 <<<"$_m1_out" | tr '\n' ' ')"
  fi
  _mut_after="$(git -C "$REPO_ROOT" status --porcelain -- "$COMMITTED_DIR" 2>&1)" \
    || mut_no "M1 git status failed after the probe run"
  _mut_after_filtered="$(printf '%s\n' "$_mut_after" | grep -v '^D ')"
  _mut_new_dirt="$(comm -13 \
    <(printf '%s\n' "$_before_filtered" | grep -v '^$' | sort) \
    <(printf '%s\n' "$_mut_after_filtered" | grep -v '^$' | sort) \
    2>/dev/null || true)"
  rm -rf "$_probe"; _probe_ours=0
  if [ -n "$_mut_new_dirt" ]; then
    mut_ok "M1 probe writing into the committed tree: guard detects the dirt — has teeth"
  else
    mut_no "M1 probe writing into the committed tree: no new dirt detected — guard is blind"
  fi
fi

rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
