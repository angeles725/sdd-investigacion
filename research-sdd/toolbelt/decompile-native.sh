#!/usr/bin/env bash
# decompile-native.sh — analysis of native binaries (ELF/PE) without a GUI.
# Base: Ghidra headless (analyzeHeadless) with the scripts' DecompileHeadless.
# Quick fallback: radare2 / objdump / readelf / strings.
#
# Usage:
#   decompile-native.sh ghidra <binary> <out-dir> [--script Script.java]
#   decompile-native.sh ghidra-evidence <binary> <new-out-dir>
#   decompile-native.sh r2     <binary>            # r2 analysis (aaa + pdf of main)
#   decompile-native.sh quick  <binary>            # file+readelf+strings (triage)
#
# Note: for interactive agent-directed decompilation, see ghidra-mcp
# (GHIDRA-MCP.md). This wrapper covers the always-available headless/batch mode.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
source "$HERE/lib/tool-env.sh"

MODE="${1:?usage: decompile-native.sh ghidra-evidence|ghidra|r2|quick <binary> ...}"
BIN="${2:?binary required}"

case "$MODE" in
  quick)
    echo "== file =="; file "$BIN"
    echo "== readelf -h =="; readelf -h "$BIN" 2>/dev/null | head -20 || { _sp="${PIPESTATUS[0]}"; [ "$_sp" -eq 0 ] || [ "$_sp" -eq 141 ] || { echo "readelf failed (rc=$_sp): $BIN" >&2; exit "$_sp"; }; }
    echo "== strings (first 40) =="
    # head closes the pipe after 40 lines, so strings dies of SIGPIPE and the pipeline's
    # first-stage exit status is 141 (= 128 + SIGPIPE(13)) — the expected early-termination
    # outcome, not a failure. Tolerate 0 and 141; surface any other status.
    strings -n 6 "$BIN" | head -40 || { _sp="${PIPESTATUS[0]}"; [ "$_sp" -eq 0 ] || [ "$_sp" -eq 141 ] || { echo "strings failed (rc=$_sp): $BIN" >&2; exit "$_sp"; }; }
    ;;
  r2)
    _r2="$(rsdd_resolve_r2)" || { echo "r2 not installed (not on PATH, brew, or /usr)" >&2; exit 3; }
    "$_r2" -q -A -c 'afl; s main; pdf' "$BIN" 2>/dev/null || "$_r2" -q -A -c 'afl' "$BIN"
    ;;
  ghidra-evidence)
    OUT="${3:?new out-dir required}"
    ADAPTER="$HERE/corroborate-ghidra.sh"
    [ -x "$ADAPTER" ] || { echo "Ghidra evidence adapter not found at $ADAPTER" >&2; exit 3; }
    exec "$ADAPTER" --input "$BIN" --output "$OUT"
    ;;
  ghidra)
    OUT="${3:?out-dir required}"; mkdir -p "$OUT"
    JAVA_HOME="$(rsdd_resolve_java_home)" || { echo "Java 21 not usable" >&2; exit 3; }
    GHIDRA_INSTALL_DIR="$(rsdd_resolve_ghidra_home)" || { echo "Ghidra headless not found" >&2; exit 3; }
    HEADLESS="$GHIDRA_INSTALL_DIR/support/analyzeHeadless"
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
    [ -x "$HEADLESS" ] || { echo "analyzeHeadless not found at $HEADLESS" >&2; exit 3; }
    PROJ="$OUT/ghidra-proj"; mkdir -p "$PROJ"
    SCRIPT_ARGS=()
    SCRIPT_DIRS="$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/ghidra_scripts"
    if [ "${4:-}" = "--script" ]; then
      _script="${5:?script}"
      _script_dir="$(cd "$(dirname "$_script")" && pwd)"
      SCRIPT_ARGS=(-postScript "$(basename "$_script")")
      SCRIPT_DIRS="$SCRIPT_DIRS;$_script_dir"
    fi
    # Imports, analyzes and (if passed) runs a decompilation postScript.
    # -postScript takes the script NAME; -scriptPath (dirs separated by ';') supplies the lookup path.
    # Source: analyzeHeadlessREADME.md §-postScript and §-scriptPath.
    "$HEADLESS" "$PROJ" research_$$ -import "$BIN" -overwrite \
      "${SCRIPT_ARGS[@]}" -scriptPath "$SCRIPT_DIRS"
    echo "OK: Ghidra headless analysis of $BIN (project in $PROJ)"
    ;;
  *) echo "unknown mode: $MODE (ghidra-evidence|ghidra|r2|quick)" >&2; exit 2 ;;
esac
