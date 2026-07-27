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
    echo "== readelf -h =="; readelf -h "$BIN" 2>/dev/null | head -20 || true
    echo "== strings (primeras 40) =="; strings -n 6 "$BIN" | head -40
    ;;
  r2)
    command -v r2 >/dev/null || { echo "r2 not installed" >&2; exit 3; }
    r2 -q -A -c 'afl; s main; pdf' "$BIN" 2>/dev/null || r2 -q -A -c 'afl' "$BIN"
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
    [ "${4:-}" = "--script" ] && SCRIPT_ARGS=(-postScript "${5:?script}")
    # Imports, analyzes and (if passed) runs a decompilation postScript.
    "$HEADLESS" "$PROJ" research_$$ -import "$BIN" -overwrite \
      "${SCRIPT_ARGS[@]}" -scriptPath "$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/ghidra_scripts"
    echo "OK: Ghidra headless analysis of $BIN (project in $PROJ)"
    ;;
  *) echo "unknown mode: $MODE (ghidra-evidence|ghidra|r2|quick)" >&2; exit 2 ;;
esac
