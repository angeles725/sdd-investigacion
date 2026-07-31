#!/usr/bin/env bash
# ghidra-c-exporter.test.sh — structural and (when Ghidra is available) live tests for
# ExportDecompiledC.java — the kit's Ghidra headless C-decompilation export script.
#
# Coverage strategy
# -----------------
# Part 1 — STRUCTURAL (no Ghidra required): verifies the promoted script's class name,
#   base class, environment-variable contract, output-format markers, and log-line prefix.
#   This is the degree of coverage achievable without a live Ghidra install and is stated
#   plainly as such — not implied to be deeper.
# Part 2 — INTEGRATION (SKIP if Ghidra unavailable): exercises the script end-to-end
#   against a synthetic fixture ELF.  Asserts a non-zero exported-function count and the
#   presence of an actual decompiled function body (`{`), in addition to structural output
#   markers.  Ends with a cleanliness assertion: git status --porcelain must match the
#   snapshot taken before the run (tracked/untracked files within the repo; ignored files
#   and paths outside the repo are not measured).
#
# --prove-teeth:
#   Block 1 (structural, no Ghidra): each tooth creates a mutant of the Java source, then
#     calls the SAME check function used in Part 1 against that mutant — not a separate
#     reimplementation.  A check that stays green on its own mutant has no teeth.
#   Block 2 (Ghidra-dependent, skipped when unavailable):
#     Tooth A — RSDD_OUT-removed mutant, CWD = sandbox: proves the env var is load-bearing
#       at runtime; the user.dir fallback lands in TMP and is torn down with it.
#     Tooth B — unique artifact in repo root, calls ck_tree_clean: proves the cleanliness
#       assertion detects dirt; uses a collision-safe name, refuses to run if it already
#       exists, and is registered in the trap before creation.
#     Tooth C — res=null mutant: proves that a totally broken exporter is caught by the
#       export-count and function-body assertions (not by markers alone).
#
# Usage: ghidra-c-exporter.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SCRIPT="$TOOLBELT/ghidra/ExportDecompiledC.java"

# shellcheck source=../lib/tool-env.sh
source "$TOOLBELT/lib/tool-env.sh"

# _tooth_b_artifact is set in Tooth B before the file is created so the trap
# can clean it up if the script is interrupted between the write and the rm.
_tooth_b_artifact=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "$_tooth_b_artifact" ] && rm -f "$_tooth_b_artifact"' EXIT

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip_tooth(){ printf '  SKIP  %s\n' "$1"; }   # precondition not met — tooth refused, not failed

echo "== ghidra-c-exporter.test.sh =="

# ── Assertion functions (shared by Part 1 and teeth) ─────────────────────────
# Teeth call these SAME functions against mutant files.  If a function is
# broken (e.g. neutered to always return 0), the corresponding tooth's negated
# call flips to failure, exposing the defect.

ck_file_present()    { [ -f "$1" ]; }
ck_extends_ghidra()  { grep -q 'extends GhidraScript' "$1" 2>/dev/null; }
ck_env_var()         { grep -q "\"$2\"" "$1" 2>/dev/null; }
ck_hdr_marker()      { grep -q 'rsdd ghidra C export' "$1" 2>/dev/null; }
ck_banner()          { grep -q '/\* ---- ' "$1" 2>/dev/null; }
ck_failed_comment()  { grep -q '/\* FAILED:' "$1" 2>/dev/null; }
ck_log_prefix()      { grep -q 'RSDD-EXPORT:' "$1" 2>/dev/null; }
ck_cap_sentinel()    { grep -q 'RSDD_MAX_FN' "$1" 2>/dev/null && grep -q 'reached' "$1" 2>/dev/null; }
# Integration-level checks (F2 — banners and FAILED comments alone do not prove decompilation)
ck_nonzero_exports() { grep -qE 'RSDD-EXPORT: [1-9][0-9]* exported' "$1" 2>/dev/null; }
ck_fn_body()         { grep -qF '{' "$1" 2>/dev/null; }   # banners/FAILED comments never contain '{'
# Cleanliness: compares git-status porcelain against a prior snapshot.
# Detects tracked-file changes and new untracked files within the repo.
# Ignored files and paths outside the repo root are NOT measured.
ck_tree_clean() { [ "$2" = "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

# ── Part 1: structural checks (no Ghidra required) ────────────────────────────

ck_file_present "$SCRIPT" \
  && ok "ExportDecompiledC.java is present in kit" \
  || no "ExportDecompiledC.java is present in kit"

ck_extends_ghidra "$SCRIPT" \
  && ok "class extends GhidraScript" \
  || no "class extends GhidraScript"

for var in RSDD_OUT RSDD_FN_FILTER RSDD_MAX_FN RSDD_TIMEOUT; do
  ck_env_var "$SCRIPT" "$var" \
    && ok "env var $var is referenced in script" \
    || no "env var $var is referenced in script"
done

ck_hdr_marker "$SCRIPT" \
  && ok "output-file header marker 'rsdd ghidra C export' present" \
  || no "output-file header marker 'rsdd ghidra C export' present"

ck_banner "$SCRIPT" \
  && ok "function banner marker '/* ---- ' present" \
  || no "function banner marker '/* ---- ' present"

ck_failed_comment "$SCRIPT" \
  && ok "failure inline comment '/* FAILED:' present" \
  || no "failure inline comment '/* FAILED:' present"

ck_log_prefix "$SCRIPT" \
  && ok "log-line prefix 'RSDD-EXPORT:' present" \
  || no "log-line prefix 'RSDD-EXPORT:' present"

ck_cap_sentinel "$SCRIPT" \
  && ok "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present" \
  || no "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present"

# ── Mutation controls block 1 (--prove-teeth, structural, no Ghidra) ─────────
#
# Each tooth writes a mutant to TMP, then calls the REAL check function against
# it (not a re-stated grep).  If the check function is neutered (always true),
# the tooth's negated call goes red, exposing the defect.

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth block 1: structural checks have discriminating power --"
  MUTANT="$TMP/Mutant.java"

  # Tooth 1: class extends something else → ck_extends_ghidra must go red.
  sed 's/extends GhidraScript/extends Object/' "$SCRIPT" > "$MUTANT"
  ! ck_extends_ghidra "$MUTANT" \
    && ok "teeth 1: ck_extends_ghidra goes red on 'extends Object' mutant" \
    || no "teeth 1: ck_extends_ghidra STAYS GREEN on mutant (theater)"

  # Tooth 2: RSDD_OUT renamed → ck_env_var must go red.
  sed 's/"RSDD_OUT"/"RSDD_XXX_DELETED"/' "$SCRIPT" > "$MUTANT"
  ! ck_env_var "$MUTANT" "RSDD_OUT" \
    && ok "teeth 2: ck_env_var goes red when RSDD_OUT is absent" \
    || no "teeth 2: ck_env_var STAYS GREEN when RSDD_OUT is absent (theater)"

  # Tooth 3: header marker changed → ck_hdr_marker must go red.
  sed 's/rsdd ghidra C export/rsdd ghidra DELETED export/' "$SCRIPT" > "$MUTANT"
  ! ck_hdr_marker "$MUTANT" \
    && ok "teeth 3: ck_hdr_marker goes red on mutant" \
    || no "teeth 3: ck_hdr_marker STAYS GREEN on mutant (theater)"

  # Tooth 4: FAILED comment changed → ck_failed_comment must go red.
  sed 's|/\* FAILED:|/* REMOVED:|g' "$SCRIPT" > "$MUTANT"
  ! ck_failed_comment "$MUTANT" \
    && ok "teeth 4: ck_failed_comment goes red on mutant" \
    || no "teeth 4: ck_failed_comment STAYS GREEN on mutant (theater)"

  # Tooth 5: log prefix changed → ck_log_prefix must go red.
  sed 's/RSDD-EXPORT:/RSDD-DELETED:/g' "$SCRIPT" > "$MUTANT"
  ! ck_log_prefix "$MUTANT" \
    && ok "teeth 5: ck_log_prefix goes red on mutant" \
    || no "teeth 5: ck_log_prefix STAYS GREEN on mutant (theater)"
fi

# ── Part 2: Ghidra-dependent integration tests (SKIP if unavailable) ─────────

GHIDRA_HOME="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"

if [ -z "$GHIDRA_HOME" ] || [ -z "$JAVA21" ] || ! rsdd_probe_ghidra "$GHIDRA_HOME"; then
  printf '  SKIP  Ghidra unavailable — integration tests and Ghidra teeth skipped\n'
  printf '  NOTE  structural checks above are the full extent of coverage without a live install\n'
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

for tool in gcc timeout; do
  command -v "$tool" >/dev/null 2>&1 || { printf '  FAIL  missing build tool: %s\n' "$tool" >&2; exit 1; }
done

# Snapshot the working tree BEFORE any Ghidra run.  A Ghidra invocation that
# falls back to user.dir (e.g. because RSDD_OUT is missing from the script)
# writes <program>.c into the cwd; ck_tree_clean catches that regression.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
before_status=""
[ -n "$REPO_ROOT" ] && before_status="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"

cat >"$TMP/fix.c" <<'CSRC'
#include <stdio.h>
static int helper(int n) { return n * 2; }
int main(void) { printf("%d\n", helper(21)); return 0; }
CSRC
gcc -O0 -fno-pie -no-pie -o "$TMP/fix.elf" "$TMP/fix.c"

# run_headless_with: run analyzeHeadless with the given script dir, run name, and env.
# RSDD_OUT is always set to the sandbox; scripts that read it correctly never write
# to user.dir (which is the repo root when run-all.sh runs from there).
run_headless_with() {
  local run="$1" scriptdir="$2"; shift 2
  mkdir -p "$TMP/$run/project" "$TMP/$run/home" \
           "$TMP/$run/xdg-cache" "$TMP/$run/xdg-config" "$TMP/$run/out"
  ( HOME="$TMP/$run/home" XDG_CACHE_HOME="$TMP/$run/xdg-cache" \
    XDG_CONFIG_HOME="$TMP/$run/xdg-config" \
    JAVA_HOME="$JAVA21" JAVA_TOOL_OPTIONS="-Duser.home=$TMP/$run/home" \
    RSDD_OUT="$TMP/$run/out" "$@" \
    timeout 240 "$GHIDRA_HOME/support/analyzeHeadless" \
      "$TMP/$run/project" cexport \
      -import "$TMP/fix.elf" -analysisTimeoutPerFile 120 \
      -scriptPath "$scriptdir" \
      -postScript ExportDecompiledC.java \
      -deleteProject \
      >"$TMP/$run/headless.log" 2>&1 )
  local rc=$?; printf '%s\n' "$rc" >"$TMP/$run/headless.rc"; return "$rc"
}

# Normal integration run with the REAL script.
if run_headless_with live "$TOOLBELT/ghidra" && [ -f "$TMP/live/out/fix.elf.c" ]; then
  ok "headless export produces <program>.c"
else
  no "headless export produces <program>.c"
  printf -- '--- headless log (first 40 lines) ---\n'
  head -40 "$TMP/live/headless.log" 2>/dev/null || true
fi

if [ -f "$TMP/live/out/fix.elf.c" ]; then
  c_out="$TMP/live/out/fix.elf.c"
  ck_hdr_marker "$c_out" \
    && ok "output file contains header comment" \
    || no "output file contains header comment"
  ck_banner "$c_out" \
    && ok "output file contains at least one function banner" \
    || no "output file contains at least one function banner"
  # F2: markers alone pass even when the exporter fails for every function.
  # Assert the export count is non-zero AND at least one function body was written.
  ck_nonzero_exports "$TMP/live/headless.log" \
    && ok "headless log reports non-zero exported function count" \
    || no "headless log reports non-zero exported function count"
  ck_fn_body "$c_out" \
    && ok "output file contains a decompiled function body ('{' found)" \
    || no "output file contains a decompiled function body ('{' found)"
  ck_log_prefix "$TMP/live/headless.log" \
    && ok "headless log contains RSDD-EXPORT: summary line" \
    || no "headless log contains RSDD-EXPORT: summary line"
fi

# Cleanliness: tracked/untracked files within the repo must be unchanged.
# (Ignored files and paths outside the repo root are not measured by
# git status --porcelain and are therefore not part of this claim.)
if [ -n "$REPO_ROOT" ]; then
  ck_tree_clean "$REPO_ROOT" "$before_status" \
    && ok "tracked/untracked files in working tree unchanged (git status --porcelain)" \
    || no "working tree changed during suite — unexpected artifact in repo ($(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -5))"
fi

# ── Mutation controls block 2 (--prove-teeth, Ghidra-dependent) ──────────────

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth block 2: Ghidra-dependent mutation controls --"

  # ---- Tooth A: RSDD_OUT-removed mutant + sandbox CWD ----
  # Proves RSDD_OUT is load-bearing at runtime.  CWD is set to $TMP/ta so the
  # user.dir fallback lands there and is torn down with TMP, not into the repo.
  # Guard: if fix.elf.c already exists in the repo root we cannot distinguish
  # "the mutant wrote it here" from "it was already there" — refuse rather than
  # assert ambiguously (same pattern as Tooth B's pre-existing guard).
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/fix.elf.c" ]; then
    skip_tooth "teeth A: '$REPO_ROOT/fix.elf.c' already exists — repo-root absence check would be ambiguous; run on a clean tree"
  else
    MUTANT_A="$TMP/mutant-a"
    mkdir -p "$MUTANT_A"
    sed 's/"RSDD_OUT"/"RSDD_XXX_DELETED"/' "$SCRIPT" > "$MUTANT_A/ExportDecompiledC.java"
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
        -scriptPath "$MUTANT_A" \
        -postScript ExportDecompiledC.java \
        -deleteProject \
        >"$TMP/ta/headless.log" 2>&1 ) || true
    # Mutant reads RSDD_XXX_DELETED → user.dir fallback → $TMP/ta/fix.elf.c.
    # Must NOT appear in RSDD_OUT ($TMP/ta/out/) nor in the repo root.
    if [ -f "$TMP/ta/fix.elf.c" ] && [ ! -f "$TMP/ta/out/fix.elf.c" ] \
       && { [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/fix.elf.c" ]; }; then
      ok "teeth A: RSDD_OUT-removed mutant writes to user.dir sandbox (env var is load-bearing)"
    else
      no "teeth A: RSDD_OUT-removed mutant — unexpected output location"
    fi
  fi

  # ---- Tooth B: unique artifact in repo root → ck_tree_clean must go red ----
  # Calls the REAL ck_tree_clean function (not a re-stated comparison) so that
  # a neutered ck_tree_clean is also caught.  Uses a unique, collision-safe name.
  # Registered in the global trap before creation; refused if the path exists.
  if [ -n "$REPO_ROOT" ]; then
    _artifact="$REPO_ROOT/rsdd-cleanliness-tooth-$$"
    if [ -e "$_artifact" ]; then
      skip_tooth "teeth B: '$_artifact' already exists — refusing to overwrite; run on a clean tree"
    else
      _tooth_b_artifact="$_artifact"   # trap will clean up on interrupt
      printf 'test-tooth-b\n' > "$_artifact"
      ! ck_tree_clean "$REPO_ROOT" "$before_status" \
        && ok "teeth B: ck_tree_clean goes red when repo root is dirtied" \
        || no "teeth B: ck_tree_clean STAYS GREEN when dirty (assertion is decoration)"
      rm -f "$_artifact"
      _tooth_b_artifact=""
    fi
  fi

  # ---- Tooth C: res=null mutant → export-count and body assertions must go red ----
  # Proves a totally broken exporter is caught; markers alone are not sufficient.
  MUTANT_C="$TMP/mutant-c"
  mkdir -p "$MUTANT_C"
  sed 's/DecompileResults res = decompiler\.decompileFunction.*/DecompileResults res = null;/' \
    "$SCRIPT" > "$MUTANT_C/ExportDecompiledC.java"
  run_headless_with tc "$MUTANT_C" || true
  ! ck_nonzero_exports "$TMP/tc/headless.log" \
    && ok "teeth C: ck_nonzero_exports goes red when exporter always fails (res=null mutant)" \
    || no "teeth C: ck_nonzero_exports STAYS GREEN on res=null mutant (theater)"
  if [ -f "$TMP/tc/out/fix.elf.c" ]; then
    ! ck_fn_body "$TMP/tc/out/fix.elf.c" \
      && ok "teeth C: ck_fn_body goes red when no C bodies are written (res=null mutant)" \
      || no "teeth C: ck_fn_body STAYS GREEN on res=null mutant (theater)"
  else
    no "teeth C: res=null mutant produced no output file (cannot check ck_fn_body)"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
