#!/usr/bin/env bash
# ghidra-c-exporter.test.sh — structural and (when Ghidra is available) live tests for
# ExportDecompiledC.java — the kit's Ghidra headless C-decompilation export script.
#
# Coverage strategy
# -----------------
# Part 1 — STRUCTURAL (no Ghidra required): verifies the promoted script's class name,
#   base class, environment-variable contract, output-format markers, and log-line prefix.
#   This is the degree of coverage achievable without a live Ghidra install and is stated
#   plainly as such — not implied to be deeper than it is.
# Part 2 — INTEGRATION (SKIP if Ghidra unavailable): exercises the script end-to-end
#   against a synthetic fixture ELF and verifies the output file structure.  Includes a
#   cleanliness assertion: the suite must not leave any artifact in the repository working
#   tree after it runs.
#
# --prove-teeth:
#   Block 1 (structural): creates trimmed copies of the Java source with known tokens
#     changed and asserts the corresponding structural checks go red.
#   Block 2 (Ghidra-dependent, skipped when Ghidra unavailable): runs Ghidra with an
#     RSDD_OUT-removed mutant script anchored to a sandbox CWD, proving the env var is
#     load-bearing at runtime; then simulates a dirty repo root to prove the cleanliness
#     assertion has teeth.
#
# Usage: ghidra-c-exporter.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SCRIPT="$TOOLBELT/ghidra/ExportDecompiledC.java"

# shellcheck source=../lib/tool-env.sh
source "$TOOLBELT/lib/tool-env.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== ghidra-c-exporter.test.sh =="

# ── Part 1: structural checks (no Ghidra required) ────────────────────────────
#
# These verify that the promoted script carries the required contract tokens.
# They do NOT prove the decompiler logic is correct — only a live Ghidra run
# can do that, and that is Part 2 (which SKIPs when Ghidra is unavailable).

[ -f "$SCRIPT" ] \
  && ok "ExportDecompiledC.java is present in kit" \
  || no "ExportDecompiledC.java is present in kit"

grep -q 'extends GhidraScript' "$SCRIPT" 2>/dev/null \
  && ok "class extends GhidraScript" \
  || no "class extends GhidraScript"

for var in RSDD_OUT RSDD_FN_FILTER RSDD_MAX_FN RSDD_TIMEOUT; do
  grep -q "\"$var\"" "$SCRIPT" 2>/dev/null \
    && ok "env var $var is referenced in script" \
    || no "env var $var is referenced in script"
done

grep -q 'rsdd ghidra C export' "$SCRIPT" 2>/dev/null \
  && ok "output-file header marker 'rsdd ghidra C export' present" \
  || no "output-file header marker 'rsdd ghidra C export' present"

grep -q '/\* ---- ' "$SCRIPT" 2>/dev/null \
  && ok "function banner open marker '/* ---- ' present" \
  || no "function banner open marker '/* ---- ' present"

grep -q '/\* FAILED:' "$SCRIPT" 2>/dev/null \
  && ok "failure inline comment '/* FAILED:' present" \
  || no "failure inline comment '/* FAILED:' present"

grep -q 'RSDD-EXPORT:' "$SCRIPT" 2>/dev/null \
  && ok "log-line prefix 'RSDD-EXPORT:' present" \
  || no "log-line prefix 'RSDD-EXPORT:' present"

grep -q 'reached' "$SCRIPT" 2>/dev/null && grep -q 'RSDD_MAX_FN' "$SCRIPT" 2>/dev/null \
  && ok "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present" \
  || no "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present"

# ── Mutation controls block 1 (--prove-teeth, structural, no Ghidra) ─────────
#
# Each tooth creates a mutant of the Java source with one critical token changed
# and asserts that the corresponding structural check goes red.  A check that
# stays green on its own mutant has no teeth and proves nothing.

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth block 1: structural checks have discriminating power --"

  MUTANT="$TMP/Mutant.java"

  # Tooth 1: class extends something else — 'extends GhidraScript' check must go red.
  sed 's/extends GhidraScript/extends Object/' "$SCRIPT" > "$MUTANT"
  ! grep -q 'extends GhidraScript' "$MUTANT" \
    && ok "teeth: 'extends GhidraScript' check goes red on mutant" \
    || no "teeth: 'extends GhidraScript' check STAYS GREEN on mutant (theater)"

  # Tooth 2: RSDD_OUT renamed — RSDD_OUT reference check must go red.
  sed 's/"RSDD_OUT"/"RSDD_XXX_DELETED"/' "$SCRIPT" > "$MUTANT"
  ! grep -q '"RSDD_OUT"' "$MUTANT" \
    && ok "teeth: RSDD_OUT env var check goes red on mutant" \
    || no "teeth: RSDD_OUT env var check STAYS GREEN on mutant (theater)"

  # Tooth 3: output header marker removed — 'rsdd ghidra C export' check must go red.
  sed 's/rsdd ghidra C export/rsdd ghidra DELETED export/' "$SCRIPT" > "$MUTANT"
  ! grep -q 'rsdd ghidra C export' "$MUTANT" \
    && ok "teeth: output-header marker check goes red on mutant" \
    || no "teeth: output-header marker check STAYS GREEN on mutant (theater)"

  # Tooth 4: FAILED comment changed — '/* FAILED:' check must go red.
  sed 's|/\* FAILED:|/* REMOVED:|g' "$SCRIPT" > "$MUTANT"
  ! grep -q '/\* FAILED:' "$MUTANT" \
    && ok "teeth: '/* FAILED:' check goes red on mutant" \
    || no "teeth: '/* FAILED:' check STAYS GREEN on mutant (theater)"

  # Tooth 5: log prefix removed — 'RSDD-EXPORT:' check must go red.
  sed 's/RSDD-EXPORT:/RSDD-DELETED:/g' "$SCRIPT" > "$MUTANT"
  ! grep -q 'RSDD-EXPORT:' "$MUTANT" \
    && ok "teeth: RSDD-EXPORT: log-prefix check goes red on mutant" \
    || no "teeth: RSDD-EXPORT: log-prefix check STAYS GREEN on mutant (theater)"
fi

# ── Part 2: Ghidra-dependent integration tests (SKIP if unavailable) ─────────

GHIDRA_HOME="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"

if [ -z "$GHIDRA_HOME" ] || [ -z "$JAVA21" ] || ! rsdd_probe_ghidra "$GHIDRA_HOME"; then
  printf '  SKIP  Ghidra unavailable — integration tests skipped\n'
  printf '  NOTE  structural checks above are the full extent of coverage without a live install\n'
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

for tool in gcc timeout; do
  command -v "$tool" >/dev/null 2>&1 || { printf '  FAIL  missing build tool: %s\n' "$tool" >&2; exit 1; }
done

# Snapshot the repository working tree BEFORE any Ghidra run.  Any Ghidra
# invocation that falls back to user.dir (e.g. because RSDD_OUT is missing)
# will dirty the tree; the cleanliness assertion at the end of this section
# detects it.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
before_status=""
[ -n "$REPO_ROOT" ] && before_status="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"

cat >"$TMP/fix.c" <<'CSRC'
#include <stdio.h>
static int helper(int n) { return n * 2; }
int main(void) { printf("%d\n", helper(21)); return 0; }
CSRC
gcc -O0 -fno-pie -no-pie -o "$TMP/fix.elf" "$TMP/fix.c"

# run_c_export: run analyzeHeadless with the REAL script and RSDD_OUT set to the
# sandbox.  The real script reads RSDD_OUT correctly, so the output never lands
# in user.dir (which would be the repo root when run from there by run-all.sh).
run_c_export() {
  local run="$1"
  mkdir -p "$TMP/$run/project" "$TMP/$run/home" \
           "$TMP/$run/xdg-cache" "$TMP/$run/xdg-config" "$TMP/$run/out"
  ( HOME="$TMP/$run/home" XDG_CACHE_HOME="$TMP/$run/xdg-cache" \
    XDG_CONFIG_HOME="$TMP/$run/xdg-config" \
    JAVA_HOME="$JAVA21" JAVA_TOOL_OPTIONS="-Duser.home=$TMP/$run/home" \
    RSDD_OUT="$TMP/$run/out" \
    timeout 240 "$GHIDRA_HOME/support/analyzeHeadless" \
      "$TMP/$run/project" cexport \
      -import "$TMP/fix.elf" -analysisTimeoutPerFile 120 \
      -scriptPath "$TOOLBELT/ghidra" \
      -postScript ExportDecompiledC.java \
      -deleteProject \
      >"$TMP/$run/headless.log" 2>&1 )
  local rc=$?
  printf '%s\n' "$rc" >"$TMP/$run/headless.rc"
  return "$rc"
}

if run_c_export live && [ -f "$TMP/live/out/fix.elf.c" ]; then
  ok "headless export produces <program>.c"
else
  no "headless export produces <program>.c"
  printf -- '--- headless log (first 40 lines) ---\n'
  head -40 "$TMP/live/headless.log" 2>/dev/null || true
fi

if [ -f "$TMP/live/out/fix.elf.c" ]; then
  c_out="$TMP/live/out/fix.elf.c"
  grep -q 'rsdd ghidra C export' "$c_out" \
    && ok "output file contains header comment" \
    || no "output file contains header comment"
  grep -q '/\* ---- ' "$c_out" \
    && ok "output file contains at least one function banner" \
    || no "output file contains at least one function banner"
  grep -q 'RSDD-EXPORT:' "$TMP/live/headless.log" \
    && ok "headless log contains RSDD-EXPORT: summary line" \
    || no "headless log contains RSDD-EXPORT: summary line"
fi

# Cleanliness assertion: the suite must not leave artifacts in the repo working tree.
# A Ghidra script that falls back to user.dir (repo root) would create <program>.c
# there; this catches the regression before it reaches a reviewer.
if [ -n "$REPO_ROOT" ]; then
  after_status="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
  [ "$before_status" = "$after_status" ] \
    && ok "suite left the repository working tree clean" \
    || no "suite left the repository working tree clean (dirty: $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -5))"
fi

# ── Mutation controls block 2 (--prove-teeth, Ghidra-dependent) ──────────────
#
# Tooth A: run Ghidra with an RSDD_OUT-removed mutant script, CWD anchored to
#   the sandbox so the user.dir fallback lands there and is torn down with TMP.
#   This proves RSDD_OUT is load-bearing at runtime, not just structurally.
#
# Tooth B: simulate a file written to the repo root (the artifact an uncorrected
#   mutation would produce) and assert the cleanliness check detects it.
#   This proves the cleanliness assertion has teeth — it is not decoration.

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth block 2: Ghidra-dependent mutation controls --"

  # Build the mutant script directory (RSDD_OUT renamed → fallback to user.dir)
  MUTANT_SCRIPTS="$TMP/mutant-scripts"
  mkdir -p "$MUTANT_SCRIPTS"
  sed 's/"RSDD_OUT"/"RSDD_XXX_DELETED"/' "$SCRIPT" > "$MUTANT_SCRIPTS/ExportDecompiledC.java"

  # Tooth A: mutant + CWD = sandbox → user.dir fallback lands in sandbox, not repo root.
  mkdir -p "$TMP/ta/project" "$TMP/ta/home" \
           "$TMP/ta/xdg-cache" "$TMP/ta/xdg-config" "$TMP/ta/out"
  ( cd "$TMP/ta" && \
    HOME="$TMP/ta/home" XDG_CACHE_HOME="$TMP/ta/xdg-cache" \
    XDG_CONFIG_HOME="$TMP/ta/xdg-config" \
    JAVA_HOME="$JAVA21" JAVA_TOOL_OPTIONS="-Duser.home=$TMP/ta/home" \
    RSDD_OUT="$TMP/ta/out" \
    timeout 240 "$GHIDRA_HOME/support/analyzeHeadless" \
      "$TMP/ta/project" cexport \
      -import "$TMP/fix.elf" -analysisTimeoutPerFile 120 \
      -scriptPath "$MUTANT_SCRIPTS" \
      -postScript ExportDecompiledC.java \
      -deleteProject \
      >"$TMP/ta/headless.log" 2>&1 ) || true
  # Mutant ignores RSDD_OUT → falls back to user.dir = $TMP/ta (the sandbox CWD).
  # File must appear in the sandbox, not in RSDD_OUT nor in the repo root.
  if [ -f "$TMP/ta/fix.elf.c" ] && [ ! -f "$TMP/ta/out/fix.elf.c" ] \
     && { [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/fix.elf.c" ]; }; then
    ok "teeth A: RSDD_OUT-removed mutant writes to user.dir sandbox (env var is load-bearing; cwd fix is essential)"
  else
    no "teeth A: RSDD_OUT-removed mutant — unexpected output location (expected in sandbox)"
  fi

  # Tooth B: simulate the artifact a cwd-unfixed mutation would leave in the repo root;
  # assert the cleanliness check detects it; clean up immediately after.
  if [ -n "$REPO_ROOT" ]; then
    _artifact="$REPO_ROOT/fix.elf.c"
    printf 'test-tooth-b\n' > "$_artifact"
    _dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
    rm -f "$_artifact"
    if [ "$before_status" != "$_dirty" ]; then
      ok "teeth B: cleanliness check goes red when repo root is dirtied (assertion has teeth)"
    else
      no "teeth B: cleanliness check STAYS GREEN when dirty (assertion is decoration)"
    fi
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
