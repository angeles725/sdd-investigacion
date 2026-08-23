#!/usr/bin/env bash
# tests/ghidra-c-exporter.test.sh — test suite for ExportDecompiledC.java (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based predicates. No Ghidra spawn. Always emits
#                    "== N passed · N failed ==".
#   slow           — real Ghidra run; requires Ghidra, gcc, java21.
#   all            — both fast and slow paths.
#
# ANTI-#128 NOTE — do NOT remove or move these slow-only guards to fast lane:
#   - RSDD_OUT sandbox guard: verifies output never writes to user.dir (cwd)
#   - tree-clean check: verifies no artifacts leaked into the repo root
#   - Tooth slow-A (RSDD_OUT-removed mutant): proves env var is load-bearing at runtime
#   - Tooth slow-B (repo-root artifact): proves ck_tree_clean detects dirt
#   - Tooth slow-C (res=null mutant): proves export-count and body assertions catch a broken exporter
#   These cannot be exercised without a real Ghidra execution.
#
# Fast-lane teeth limitation (R2 exception — declared, not concealed):
#   The broken.json teeth prove the ASSERT bites against a synthetic broken fixture.
#   This does NOT prove that a SUT regression (change to ExportDecompiledC.java) is
#   caught — that axis is covered by Tooth slow-C in the slow lane (res=null mutant).
#   The fast-lane win: the suite runs everywhere, including CI without Ghidra.
#
# Strengthened ck_fn_body (vs. prior '{' proxy):
#   Now requires at least one ';' in the C output, not just a brace.
#   An empty '{}' body (brace only, no C statements) no longer passes this check.
#   FAILED-only output (all functions failed decompilation) also carries no ';'.
#
# Exit 2 when the SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SCRIPT="$TOOLBELT/ghidra/ExportDecompiledC.java"

# Source lane helper (idempotent; aborts on invalid RSDD_TEST_LANE value).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the SUT does not exist yet.
[ -f "$SCRIPT" ] || { echo "FATAL: SUT not found: $SCRIPT" >&2; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip_tooth(){ printf '  SKIP  %s\n' "$1"; }

echo "== ghidra-c-exporter.test.sh =="

# Determine active lane (aborts on invalid value per §7 anti-silent-zero).
_lane="$(rsdd_lane)"

# Fixture paths resolved here; existence checked in fast-lane section.
_HAPPY_FIX="$(rsdd_lane_fixture ghidra-c-exporter happy)"
_BROKEN_FIX="$(rsdd_lane_fixture ghidra-c-exporter broken)"

TMP="$(mktemp -d)"
_tooth_b_artifact=""
trap 'rm -rf "$TMP"; [ -n "$_tooth_b_artifact" ] && rm -f "$_tooth_b_artifact"' EXIT

# Track slow-lane readiness so --prove-teeth can gate Ghidra-dependent teeth.
_slow_skip=1
REPO_ROOT=""
_before_status=""

# ── Predicate functions (shared by structural, fast, and slow sections) ───────
# Each function takes a FILE PATH argument and returns 0 (pass) or non-zero (fail).

# Structural predicates — run against ExportDecompiledC.java source.
ck_file_present()    { [ -f "$1" ]; }
ck_extends_ghidra()  { grep -q 'extends GhidraScript' "$1" 2>/dev/null; }
ck_env_var()         { grep -q "\"$2\"" "$1" 2>/dev/null; }

# Output predicates — run against the .c output file or log-line file.
ck_hdr_marker()      { grep -q 'rsdd ghidra C export' "$1" 2>/dev/null; }
ck_banner()          { grep -q '/\* ---- ' "$1" 2>/dev/null; }
ck_failed_comment()  { grep -q '/\* FAILED:' "$1" 2>/dev/null; }
ck_log_prefix()      { grep -q 'RSDD-EXPORT:' "$1" 2>/dev/null; }
ck_cap_sentinel()    { grep -q 'RSDD_MAX_FN' "$1" 2>/dev/null && grep -q 'reached' "$1" 2>/dev/null; }
ck_nonzero_exports() { grep -qE 'RSDD-EXPORT: [1-9][0-9]* exported' "$1" 2>/dev/null; }

# ck_fn_body — STRENGTHENED vs. the prior '{' proxy.
# Requires at least one C statement (';') in the file.
# Empty '{}' bodies never carry a semicolon; '/* FAILED: */' comments do not either.
# A file where every function failed decompilation (all FAILED: markers) carries no ';'.
ck_fn_body()         { grep -qF ';' "$1" 2>/dev/null; }

# Cleanliness (slow-only usage; defined here so teeth can call the real function).
ck_tree_clean() { [ "$2" = "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

# ── Structural checks (always run; no Ghidra required) ────────────────────────

ck_file_present "$SCRIPT" \
  && ok "ExportDecompiledC.java is present in kit" \
  || no "ExportDecompiledC.java is present in kit"

ck_extends_ghidra "$SCRIPT" \
  && ok "class extends GhidraScript" \
  || no "class extends GhidraScript"

for _var in RSDD_OUT RSDD_FN_FILTER RSDD_MAX_FN RSDD_TIMEOUT; do
  ck_env_var "$SCRIPT" "$_var" \
    && ok "env var $_var is referenced in script" \
    || no "env var $_var is referenced in script"
done

ck_hdr_marker "$SCRIPT" \
  && ok "output-file header marker 'rsdd ghidra C export' present in source" \
  || no "output-file header marker 'rsdd ghidra C export' present in source"

ck_banner "$SCRIPT" \
  && ok "function banner marker '/* ---- ' present in source" \
  || no "function banner marker '/* ---- ' present in source"

ck_failed_comment "$SCRIPT" \
  && ok "failure inline comment '/* FAILED:' present in source" \
  || no "failure inline comment '/* FAILED:' present in source"

ck_log_prefix "$SCRIPT" \
  && ok "log-line prefix 'RSDD-EXPORT:' present in source" \
  || no "log-line prefix 'RSDD-EXPORT:' present in source"

ck_cap_sentinel "$SCRIPT" \
  && ok "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present in source" \
  || no "truncation-cap sentinel 'RSDD_MAX_FN ... reached' present in source"

# ── FAST LANE — fixture-based assertions (no Ghidra spawn) ───────────────────
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-§7: fixtures must exist before asserting against them.
  for _fix in "$_HAPPY_FIX" "$_BROKEN_FIX"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite ghidra-c-exporter" >&2
      exit 1
    fi
  done

  # Extract happy-fixture fields into temp files for predicate functions.
  python3 - "$_HAPPY_FIX" "$TMP/happy_c.txt" "$TMP/happy_log.txt" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
pathlib.Path(sys.argv[2]).write_text(d['c_output'])
pathlib.Path(sys.argv[3]).write_text(d['summary_line'])
PY

  ck_hdr_marker "$TMP/happy_c.txt" \
    && ok "F1-fast: header marker 'rsdd ghidra C export' in fixture c_output" \
    || no "F1-fast: header marker 'rsdd ghidra C export' in fixture c_output"

  ck_banner "$TMP/happy_c.txt" \
    && ok "F2-fast: function banner '/* ---- ' in fixture c_output" \
    || no "F2-fast: function banner '/* ---- ' in fixture c_output"

  ck_nonzero_exports "$TMP/happy_log.txt" \
    && ok "F3-fast: fixture summary_line reports non-zero exported count" \
    || no "F3-fast: fixture summary_line reports non-zero exported count"

  ck_fn_body "$TMP/happy_c.txt" \
    && ok "F4-fast: fixture c_output contains a decompiled function body (';' found)" \
    || no "F4-fast: fixture c_output contains a decompiled function body (';' found)"

  ck_log_prefix "$TMP/happy_log.txt" \
    && ok "F5-fast: fixture summary_line carries RSDD-EXPORT: prefix" \
    || no "F5-fast: fixture summary_line carries RSDD-EXPORT: prefix"

fi # fast | all

# ── SLOW LANE — real Ghidra run ───────────────────────────────────────────────
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  # shellcheck source=../lib/tool-env.sh
  source "$TOOLBELT/lib/tool-env.sh"

  GHIDRA_HOME="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
  JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"

  if [ -z "$GHIDRA_HOME" ] || [ -z "$JAVA21" ] || ! rsdd_probe_ghidra "$GHIDRA_HOME"; then
    echo "SLOW lane: usable Ghidra unavailable; slow-lane tests skipped." >&2
  else
    _slow_skip=0
    for _tool in gcc timeout; do
      command -v "$_tool" >/dev/null 2>&1 || {
        echo "SLOW lane: '$_tool' not found; slow-lane tests skipped." >&2
        _slow_skip=1; break
      }
    done

    if [[ "$_slow_skip" -eq 0 ]]; then

      # Snapshot working tree BEFORE any Ghidra run.  A Ghidra invocation that
      # falls back to user.dir (e.g. RSDD_OUT absent) writes <program>.c into cwd;
      # ck_tree_clean catches that regression.  ANTI-#128: guard stays slow-only.
      REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$REPO_ROOT" ] && \
        _before_status="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"

      cat >"$TMP/fix.c" <<'CSRC'
#include <stdio.h>
static int helper(int n) { return n * 2; }
int main(void) { printf("%d\n", helper(21)); return 0; }
CSRC
      gcc -O0 -fno-pie -no-pie -o "$TMP/fix.elf" "$TMP/fix.c"

      # run_headless_with <run-name> <scriptdir> [extra-env ...]
      # RSDD_OUT is always set to the sandbox so scripts that read it correctly
      # never write to user.dir (the repo root when run-all.sh runs from there).
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

      if run_headless_with live "$TOOLBELT/ghidra" && [ -f "$TMP/live/out/fix.elf.c" ]; then
        ok "slow S1: headless export produces fix.elf.c"
      else
        no "slow S1: headless export produces fix.elf.c"
        printf -- '--- headless log (first 40 lines) ---\n'
        head -40 "$TMP/live/headless.log" 2>/dev/null || true
      fi

      if [ -f "$TMP/live/out/fix.elf.c" ]; then
        ck_hdr_marker "$TMP/live/out/fix.elf.c" \
          && ok "slow S2: output file contains header comment" \
          || no "slow S2: output file contains header comment"
        ck_banner "$TMP/live/out/fix.elf.c" \
          && ok "slow S3: output file contains at least one function banner" \
          || no "slow S3: output file contains at least one function banner"
        # F2-guard: markers alone pass even when the exporter fails for every function.
        # Assert non-zero export count AND that a real function body (';') was written.
        ck_nonzero_exports "$TMP/live/headless.log" \
          && ok "slow S4: headless log reports non-zero exported function count" \
          || no "slow S4: headless log reports non-zero exported function count"
        ck_fn_body "$TMP/live/out/fix.elf.c" \
          && ok "slow S5: output contains a decompiled function body (';' found)" \
          || no "slow S5: output contains a decompiled function body (';' found)"
        ck_log_prefix "$TMP/live/headless.log" \
          && ok "slow S6: headless log contains RSDD-EXPORT: summary line" \
          || no "slow S6: headless log contains RSDD-EXPORT: summary line"
      fi

      # ANTI-#128: tree-clean guard MUST stay slow-only.
      # Detected changed tracked/untracked files within the repo root.
      # Ignored files and paths outside the repo root are not measured.
      if [ -n "$REPO_ROOT" ]; then
        ck_tree_clean "$REPO_ROOT" "$_before_status" \
          && ok "slow S7: tracked/untracked files in working tree unchanged" \
          || no "slow S7: working tree changed during suite — unexpected artifact in repo ($(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -5))"
      fi

    fi # _slow_skip == 0
  fi # Ghidra available

fi # slow | all

# ── --prove-teeth: mutation controls ─────────────────────────────────────────
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth --"
  MUTANT="$TMP/Mutant.java"

  # ── Structural source teeth (always; no Ghidra) ──────────────────────────
  # Each tooth mutates ExportDecompiledC.java and calls the REAL check function.
  # A neutered check (always returns 0) causes the negated call to fail → exposed.

  sed 's/extends GhidraScript/extends Object/' "$SCRIPT" > "$MUTANT"
  ! ck_extends_ghidra "$MUTANT" \
    && ok "tooth-src-1: ck_extends_ghidra goes RED on 'extends Object' mutant" \
    || no "tooth-src-1: ck_extends_ghidra STAYS GREEN on mutant (theater)"

  sed 's/"RSDD_OUT"/"RSDD_XXX_DELETED"/' "$SCRIPT" > "$MUTANT"
  ! ck_env_var "$MUTANT" "RSDD_OUT" \
    && ok "tooth-src-2: ck_env_var goes RED when RSDD_OUT is absent" \
    || no "tooth-src-2: ck_env_var STAYS GREEN when RSDD_OUT is absent (theater)"

  sed 's/rsdd ghidra C export/rsdd ghidra DELETED export/' "$SCRIPT" > "$MUTANT"
  ! ck_hdr_marker "$MUTANT" \
    && ok "tooth-src-3: ck_hdr_marker goes RED on mutant" \
    || no "tooth-src-3: ck_hdr_marker STAYS GREEN on mutant (theater)"

  sed 's|/\* FAILED:|/* REMOVED:|g' "$SCRIPT" > "$MUTANT"
  ! ck_failed_comment "$MUTANT" \
    && ok "tooth-src-4: ck_failed_comment goes RED on mutant" \
    || no "tooth-src-4: ck_failed_comment STAYS GREEN on mutant (theater)"

  sed 's/RSDD-EXPORT:/RSDD-DELETED:/g' "$SCRIPT" > "$MUTANT"
  ! ck_log_prefix "$MUTANT" \
    && ok "tooth-src-5: ck_log_prefix goes RED on mutant" \
    || no "tooth-src-5: ck_log_prefix STAYS GREEN on mutant (theater)"

  # ── Fast-lane fixture teeth (broken.json; no Ghidra required) ────────────
  # R2 exception (declared in header): proves the ASSERT bites against a synthetic
  # fixture, not that a SUT regression is caught.  Slow-lane Tooth slow-C covers that.
  if [[ ! -f "$_BROKEN_FIX" ]]; then
    echo "FATAL: broken fixture missing: $_BROKEN_FIX (cannot run fixture teeth)" >&2
  else
    python3 - "$_BROKEN_FIX" "$TMP/broken_c.txt" "$TMP/broken_log.txt" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
pathlib.Path(sys.argv[2]).write_text(d['c_output'])
pathlib.Path(sys.argv[3]).write_text(d['summary_line'])
PY

    # tooth-fix-1: 0 exported → ck_nonzero_exports must go RED.
    ! ck_nonzero_exports "$TMP/broken_log.txt" \
      && ok "tooth-fix-1: ck_nonzero_exports goes RED on broken fixture (0 exported)" \
      || no "tooth-fix-1: ck_nonzero_exports STAYS GREEN on broken fixture (theater)"

    # tooth-fix-2: all FAILED: markers, no ';' → ck_fn_body must go RED.
    ! ck_fn_body "$TMP/broken_c.txt" \
      && ok "tooth-fix-2: ck_fn_body goes RED on broken fixture (no ';' in FAILED-only output)" \
      || no "tooth-fix-2: ck_fn_body STAYS GREEN on broken fixture (theater)"

    # tooth-fix-3: predicate-neutralization axis.
    # Redefine ck_fn_body to always return 0 (neutralized).
    # The neutralized predicate PASSES on the broken fixture — theater.
    # This confirms the real ck_fn_body is load-bearing: removing it enables a false pass.
    _ck_fn_body_neutral() { return 0; }
    _ck_fn_body_neutral "$TMP/broken_c.txt" \
      && ok "tooth-fix-3: neutralized ck_fn_body PASSES on broken fixture (predicate is load-bearing; removal = theater)" \
      || no "tooth-fix-3: neutralized ck_fn_body went RED — neutralization tooth logic error"
  fi

  # ── Slow-lane Ghidra teeth (require real Ghidra run to have completed) ────
  if [[ "$_slow_skip" -eq 0 ]]; then
    echo "-- teeth: slow-lane Ghidra mutation controls --"

    # ---- Tooth slow-A: RSDD_OUT-removed mutant + sandbox CWD ----
    # Proves RSDD_OUT is load-bearing at runtime.  CWD = $TMP/ta so the user.dir
    # fallback lands in TMP and is torn down with it.
    if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/fix.elf.c" ]; then
      skip_tooth "tooth-slow-A: '$REPO_ROOT/fix.elf.c' already exists — run on a clean tree"
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
        ok "tooth-slow-A: RSDD_OUT-removed mutant writes to user.dir sandbox (env var is load-bearing)"
      else
        no "tooth-slow-A: RSDD_OUT-removed mutant — unexpected output location"
      fi
    fi

    # ---- Tooth slow-B: unique artifact in repo root → ck_tree_clean must go RED ----
    # Calls the REAL ck_tree_clean; a neutered version would stay GREEN and be caught.
    if [ -n "$REPO_ROOT" ]; then
      _artifact="$REPO_ROOT/rsdd-cleanliness-tooth-$$"
      if [ -e "$_artifact" ]; then
        skip_tooth "tooth-slow-B: '$_artifact' already exists — refusing to overwrite; run on a clean tree"
      else
        _tooth_b_artifact="$_artifact"
        printf 'test-tooth-b\n' > "$_artifact"
        ! ck_tree_clean "$REPO_ROOT" "$_before_status" \
          && ok "tooth-slow-B: ck_tree_clean goes RED when repo root is dirtied" \
          || no "tooth-slow-B: ck_tree_clean STAYS GREEN when dirty (assertion is decoration)"
        rm -f "$_artifact"
        _tooth_b_artifact=""
      fi
    fi

    # ---- Tooth slow-C: res=null mutant → export-count and body assertions must go RED ----
    # Proves a totally broken exporter is caught; markers alone are not sufficient.
    MUTANT_C="$TMP/mutant-c"
    mkdir -p "$MUTANT_C"
    sed 's/DecompileResults res = decompiler\.decompileFunction.*/DecompileResults res = null;/' \
      "$SCRIPT" > "$MUTANT_C/ExportDecompiledC.java"
    run_headless_with tc "$MUTANT_C" || true
    ! ck_nonzero_exports "$TMP/tc/headless.log" \
      && ok "tooth-slow-C: ck_nonzero_exports goes RED when exporter always fails (res=null mutant)" \
      || no "tooth-slow-C: ck_nonzero_exports STAYS GREEN on res=null mutant (theater)"
    if [ -f "$TMP/tc/out/fix.elf.c" ]; then
      ! ck_fn_body "$TMP/tc/out/fix.elf.c" \
        && ok "tooth-slow-C: ck_fn_body goes RED when no C bodies are written (res=null mutant)" \
        || no "tooth-slow-C: ck_fn_body STAYS GREEN on res=null mutant (theater)"
    else
      no "tooth-slow-C: res=null mutant produced no output file (cannot check ck_fn_body)"
    fi

  fi # _slow_skip == 0

fi # --prove-teeth

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
