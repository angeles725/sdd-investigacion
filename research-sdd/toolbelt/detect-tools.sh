#!/usr/bin/env bash
# detect-tools.sh — probe the REAL availability of RE/decompile tools and print a
# capability report. READ-ONLY: it never installs anything (that is install-tool.sh).
#
# Why this exists: do NOT infer availability from `which` alone. A tool can be
# installed under linuxbrew's Cellar, a dotnet tools dir, or a jar path and still
# be absent from PATH — assuming "Ghidra not available" when it WAS reachable via
# linuxbrew cost the first native block its decompiler depth (lesson: niagara).
#
# Usage:
#   detect-tools.sh                 # print report to stdout AND cache it
#   detect-tools.sh --cache <file>  # cache to <file> (default: ./.research-tools.txt)
#   detect-tools.sh --quiet         # only write the cache, no stdout
#
# Exit: always 0 (a report, not a gate). Each row is available|MISSING + the path.
set -u

CACHE="./.research-tools.txt"
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cache) CACHE="${2:?path}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "usage: $0 [--cache <file>] [--quiet]" >&2; exit 2 ;;
  esac
done

# Resolve a command: PATH first, then a list of candidate absolute paths / globs.
# Echoes the resolved path (or empty) and returns 0 if found.
resolve() {
  cmd="$1"; shift
  p="$(command -v "$cmd" 2>/dev/null || true)"
  if [ -n "$p" ]; then echo "$p"; return 0; fi
  for cand in "$@"; do
    # expand globs (Cellar versioned paths) without failing when none match
    for g in $cand; do
      [ -e "$g" ] && { echo "$g"; return 0; }
    done
  done
  return 1
}

BREW="${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}"

# row "<label>" "<cmd>" [candidate paths/globs...]
row() {
  label="$1"; cmd="$2"; shift 2
  if path="$(resolve "$cmd" "$@")"; then
    printf '  %-22s available   %s\n' "$label" "$path"
  else
    printf '  %-22s MISSING     (not on PATH nor known install dirs)\n' "$label"
  fi
}

# jar-style tools: probe candidate jar paths directly (no command form).
jarrow() {
  label="$1"; shift
  for cand in "$@"; do
    for g in $cand; do
      [ -e "$g" ] && { printf '  %-22s available   %s\n' "$label" "$g"; return 0; }
    done
  done
  printf '  %-22s MISSING     (jar not found; set the matching env var)\n' "$label"
}

report() {
  echo "== Research-SDD tool capability report =="
  echo "host: $(uname -srm 2>/dev/null) · date: $(date -u +%FT%TZ) · brew: $BREW"
  echo ""
  echo "[ native / binary ]"
  row "Ghidra headless" analyzeHeadless \
      "${GHIDRA_INSTALL_DIR:-}/support/analyzeHeadless" \
      "$BREW/Cellar/ghidra/*/libexec/support/analyzeHeadless" \
      "$BREW/opt/ghidra/libexec/support/analyzeHeadless" \
      "/opt/ghidra*/support/analyzeHeadless"
  row "radare2" r2 "$BREW/bin/r2" /usr/bin/r2
  row "objdump" objdump "$BREW/bin/objdump" /usr/bin/objdump
  row "readelf" readelf "$BREW/bin/readelf" /usr/bin/readelf
  row "nm" nm "$BREW/bin/nm" /usr/bin/nm
  row "strings" strings "$BREW/bin/strings" /usr/bin/strings
  echo ""
  echo "[ java ]"
  row "java" java "${JAVA_HOME:-}/bin/java" "$BREW/opt/openjdk@21/bin/java"
  row "javap" javap "${JAVA_HOME:-}/bin/javap" "$BREW/opt/openjdk@21/bin/javap"
  jarrow "Vineflower (jar)" "${VINEFLOWER:-}" "$HOME/modules/Prototipos/Reflow/vineflower.jar" "$BREW/opt/vineflower/*.jar"
  jarrow "CFR (jar)" "${CFR:-}" "$HOME/modules/Prototipos/Reflow/cfr.jar"
  jarrow "Procyon (jar)" "${PROCYON:-}" "$HOME/modules/Prototipos/modulos/procyon.jar"
  echo ""
  echo "[ android ]"
  row "jadx" jadx "$BREW/bin/jadx" /usr/bin/jadx
  row "apktool" apktool "$BREW/bin/apktool"
  echo ""
  echo "[ .net ]"
  row "ilspycmd" ilspycmd "$HOME/.dotnet/tools/ilspycmd"
  echo ""
  echo "[ firmware ]"
  row "binwalk" binwalk /usr/bin/binwalk "$BREW/bin/binwalk"
  row "yara" yara "$BREW/bin/yara" /usr/bin/yara
  echo ""
  echo "[ docs / web ]"
  row "pdftotext" pdftotext "$BREW/bin/pdftotext" /usr/bin/pdftotext
  row "pdfinfo" pdfinfo "$BREW/bin/pdfinfo" /usr/bin/pdfinfo
  row "tesseract" tesseract "$BREW/bin/tesseract" /usr/bin/tesseract
  row "pandoc" pandoc "$BREW/bin/pandoc" /usr/bin/pandoc
  # extract-pdf.sh Tier-1 stack (RESEARCH_SDD_VENV, default ~/.local/share/research-sdd-tools/venv).
  # pymupdf4llm is a venv module, not a CLI — probe it by import, mirroring extract-pdf.sh's own gate.
  PDF_VENV="${RESEARCH_SDD_VENV:-$HOME/.local/share/research-sdd-tools/venv}"
  if [ -x "$PDF_VENV/bin/python" ] && "$PDF_VENV/bin/python" -c 'import pymupdf4llm' 2>/dev/null; then
    printf '  %-22s available   %s\n' "pymupdf4llm" "$PDF_VENV/bin/python"
  else
    printf '  %-22s MISSING     (%s — extract-pdf.sh Tier 1)\n' "pymupdf4llm" "$PDF_VENV"
  fi
  row "ocrmypdf" ocrmypdf "$PDF_VENV/bin/ocrmypdf" "$BREW/bin/ocrmypdf" /usr/bin/ocrmypdf
  row "marker" marker_single "$PDF_VENV/bin/marker_single" "$BREW/bin/marker_single"
  row "docling" docling "$PDF_VENV/bin/docling" "$BREW/bin/docling"
  echo ""
  echo "[ python bytecode ]"
  row "pycdc" pycdc "$HOME/dev/pycdc/pycdc"
  echo ""
  echo "[ dynamic / instrumentation ]"
  # frida-tools is a pipx/venv install → CLIs live in ~/.local/bin (see install-tool.sh frida).
  row "frida" frida "$HOME/.local/bin/frida" "$BREW/bin/frida"
  row "frida-trace" frida-trace "$HOME/.local/bin/frida-trace" "$BREW/bin/frida-trace"
  echo ""
  echo "Note: MISSING here means not detected — try install-tool.sh <recipe> before"
  echo "concluding a tool is unavailable. Re-run this script after any install."
}

OUT="$(report)"
printf '%s\n' "$OUT" > "$CACHE" 2>/dev/null || true
[ "$QUIET" -eq 1 ] || printf '%s\n' "$OUT"
[ "$QUIET" -eq 1 ] && echo "tool capability report cached → $CACHE"
exit 0
