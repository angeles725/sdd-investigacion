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
#   detect-tools.sh                          # print report to stdout AND cache it
#   detect-tools.sh --cache <file>           # cache to <file> (default: ./.research-tools.txt)
#   detect-tools.sh --quiet                  # only write the cache, no stdout
#   detect-tools.sh --require <tool>[,...]   # gate: non-zero if any named tool is not AVAILABLE
#
# Exit: 0 = report produced (default); 1 = --require gate failed; 2 = usage error.
# Status values in report: AVAILABLE | UNUSABLE | MISSING | PROBE_FAILED.
# PROBE_FAILED means the probe could not complete (timeout/127) — distinct from MISSING.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
source "$HERE/lib/tool-env.sh"

CACHE="./.research-tools.txt"
QUIET=0
REQUIRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:?path}"; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    --require) REQUIRE="${2-}"; [ -n "$REQUIRE" ] || { echo "usage: $0 [--cache <file>] [--quiet] [--require <tool>[,<tool>...]]" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: $0 [--cache <file>] [--quiet] [--require <tool>[,<tool>...]]" >&2; exit 2 ;;
  esac
done

# require_label <name> — maps a canonical tool name to its report label.
# Returns 0 on success, 1 for unknown names (caller exits 2).
require_label() {
  case "$1" in
    ghidra)        printf '%s\n' "Ghidra headless" ;;
    r2|radare2)    printf '%s\n' "radare2" ;;
    objdump)       printf '%s\n' "objdump" ;;
    readelf)       printf '%s\n' "readelf" ;;
    nm)            printf '%s\n' "nm" ;;
    strings)       printf '%s\n' "strings" ;;
    tshark)        printf '%s\n' "tshark" ;;
    tcpdump)       printf '%s\n' "tcpdump" ;;
    gdb)           printf '%s\n' "gdb" ;;
    gdb-multiarch) printf '%s\n' "gdb-multiarch" ;;
    strace)        printf '%s\n' "strace" ;;
    ltrace)        printf '%s\n' "ltrace" ;;
    qemu-system)   printf '%s\n' "QEMU system" ;;
    qemu-user)     printf '%s\n' "QEMU user-static" ;;
    qemu-img)      printf '%s\n' "QEMU image" ;;
    vineflower)    printf '%s\n' "Vineflower (jar)" ;;
    cfr)           printf '%s\n' "CFR (jar)" ;;
    procyon)       printf '%s\n' "Procyon (jar)" ;;
    jadx)          printf '%s\n' "jadx" ;;
    apktool)       printf '%s\n' "apktool" ;;
    ilspycmd)      printf '%s\n' "ilspycmd" ;;
    binwalk)       printf '%s\n' "binwalk" ;;
    yara)          printf '%s\n' "yara" ;;
    pdftotext)     printf '%s\n' "pdftotext" ;;
    pdfinfo)       printf '%s\n' "pdfinfo" ;;
    tesseract)     printf '%s\n' "tesseract" ;;
    pandoc)        printf '%s\n' "pandoc" ;;
    pymupdf4llm)   printf '%s\n' "pymupdf4llm" ;;
    ocrmypdf)      printf '%s\n' "ocrmypdf" ;;
    marker)        printf '%s\n' "marker" ;;
    docling)       printf '%s\n' "docling" ;;
    pycdc)         printf '%s\n' "pycdc" ;;
    frida)         printf '%s\n' "frida" ;;
    frida-trace)   printf '%s\n' "frida-trace" ;;
    java|java21)   printf '%s\n' "Java 21" ;;
    javap)         printf '%s\n' "javap 21" ;;
    *) return 1 ;;
  esac
}

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

BREW="$(rsdd_brew_prefix || true)"

# row "<label>" "<cmd>" "<smoke-arg>" [candidate paths/globs...]
row() {
  label="$1"; cmd="$2"; smoke_arg="$3"; shift 3
  if path="$(resolve "$cmd" "$@")"; then
    rsdd_run_probe "$path" "$smoke_arg"; probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
      printf '  %-22s AVAILABLE   %s\n' "$label" "$path"
    elif [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 127 ]; then
      # 124 = timeout killed the probe; 127 = timeout binary absent.
      # Either way the probe machinery could not run — distinct from UNUSABLE.
      printf '  %-22s PROBE_FAILED %s (probe error: exit %d)\n' "$label" "$path" "$probe_rc"
    else
      printf '  %-22s UNUSABLE    %s (smoke test failed)\n' "$label" "$path"
    fi
  else
    printf '  %-22s MISSING     (not on PATH nor known install dirs)\n' "$label"
  fi
}

# Probe the resolved console script itself: pipx and venv launchers are commonly
# symlinks and do not necessarily have a sibling `python` executable.
python_row() {
  label="$1"; cmd="$2"; smoke_arg="$3"; shift 3
  if path="$(resolve "$cmd" "$@")"; then
    if RSDD_PROBE_TIMEOUT="${RSDD_PYTHON_PROBE_TIMEOUT:-20}" rsdd_run_probe "$path" "$smoke_arg"; then
      printf '  %-22s AVAILABLE   %s\n' "$label" "$path"
    else
      printf '  %-22s UNUSABLE    %s (entrypoint smoke test failed)\n' "$label" "$path"
    fi
  else
    printf '  %-22s MISSING     (not on PATH nor known install dirs)\n' "$label"
  fi
}

jarrow() {
  label="$1"; name="$2"; digest=""
  if jar="$(rsdd_resolve_java_jar "$name")"; then
    if rsdd_probe_java_jar "$name" "$jar" && digest="$(rsdd_file_sha256 "$jar")"; then
      printf '  %-22s AVAILABLE   %s (sha256=%s)\n' "$label" "$jar" "$digest"
    else
      printf '  %-22s UNUSABLE    %s (archive structure/digest validation failed)\n' "$label" "$jar"
    fi
  else
    printf '  %-22s MISSING     (jar not found; set the matching env var)\n' "$label"
  fi
}

report() {
  echo "== Research-SDD tool capability report =="
  echo "host: $(uname -srm 2>/dev/null) · date: $(date -u +%FT%TZ) · brew: $BREW"
  echo ""
  echo "[ native / binary ]"
  if ghidra_home="$(rsdd_resolve_ghidra_home)"; then
    if rsdd_probe_ghidra "$ghidra_home"; then
      printf '  %-22s AVAILABLE   %s\n' "Ghidra headless" "$ghidra_home/support/analyzeHeadless"
    else
      printf '  %-22s UNUSABLE    %s (headless smoke test failed)\n' "Ghidra headless" "$ghidra_home/support/analyzeHeadless"
    fi
  else
    printf '  %-22s MISSING     (not on PATH nor known install dirs)\n' "Ghidra headless"
  fi
  row "radare2" r2 -v "${BREW:+$BREW/bin/r2}" /usr/bin/r2
  row "objdump" objdump --version "${BREW:+$BREW/bin/objdump}" /usr/bin/objdump
  row "readelf" readelf --version "${BREW:+$BREW/bin/readelf}" /usr/bin/readelf
  row "nm" nm --version "${BREW:+$BREW/bin/nm}" /usr/bin/nm
  row "strings" strings --version "${BREW:+$BREW/bin/strings}" /usr/bin/strings
  echo ""
  echo "[ dynamic / network / emulation ]"
  row "tshark" tshark --version /usr/bin/tshark
  row "tcpdump" tcpdump --version /usr/bin/tcpdump
  row "gdb" gdb --version /usr/bin/gdb
  row "gdb-multiarch" gdb-multiarch --version /usr/bin/gdb-multiarch
  row "strace" strace --version /usr/bin/strace
  row "ltrace" ltrace --version /usr/bin/ltrace
  row "QEMU system" qemu-system-x86_64 --version /usr/bin/qemu-system-x86_64
  row "QEMU user-static" qemu-arm-static --version /usr/bin/qemu-arm-static
  row "QEMU image" qemu-img --version /usr/bin/qemu-img
  echo ""
  echo "[ java ]"
  if java_home="$(rsdd_resolve_java_home)"; then
    printf '  %-22s AVAILABLE   %s\n' "Java 21" "$java_home/bin/java"
    printf '  %-22s AVAILABLE   %s\n' "javap 21" "$java_home/bin/javap"
  else
    printf '  %-22s MISSING     (usable Java 21 + javap not found)\n' "Java 21"
    printf '  %-22s MISSING     (usable Java 21 + javap not found)\n' "javap 21"
  fi
  jarrow "Vineflower (jar)" vineflower
  jarrow "CFR (jar)" cfr
  jarrow "Procyon (jar)" procyon
  echo ""
  echo "[ android ]"
  row "jadx" jadx --version "${BREW:+$BREW/bin/jadx}" /usr/bin/jadx
  row "apktool" apktool --version "${BREW:+$BREW/bin/apktool}"
  echo ""
  echo "[ .net ]"
  row "ilspycmd" ilspycmd --version "$HOME/.dotnet/tools/ilspycmd"
  echo ""
  echo "[ firmware ]"
  row "binwalk" binwalk --help /usr/bin/binwalk "${BREW:+$BREW/bin/binwalk}"
  row "yara" yara --version "${BREW:+$BREW/bin/yara}" /usr/bin/yara
  if hs_version="$(rsdd_pkg_config --modversion libhs 2>/dev/null)"; then
    printf '  %-22s AVAILABLE   libhs %s (command-local system pkg-config path)\n' "Hyperscan pkg-config" "$hs_version"
  else
    printf '  %-22s MISSING     (libhs.pc not usable through pkg-config)\n' "Hyperscan pkg-config"
  fi
  echo ""
  echo "[ docs / web ]"
  row "pdftotext" pdftotext -v "${BREW:+$BREW/bin/pdftotext}" /usr/bin/pdftotext
  row "pdfinfo" pdfinfo -v "${BREW:+$BREW/bin/pdfinfo}" /usr/bin/pdfinfo
  row "tesseract" tesseract --version "${BREW:+$BREW/bin/tesseract}" /usr/bin/tesseract
  row "pandoc" pandoc --version "${BREW:+$BREW/bin/pandoc}" /usr/bin/pandoc
  # extract-pdf.sh Tier-1 stack (RESEARCH_SDD_VENV, default ~/.local/share/research-sdd-tools/venv).
  # pymupdf4llm is a venv module, not a CLI — probe it by import, mirroring extract-pdf.sh's own gate.
  PDF_VENV="${RESEARCH_SDD_VENV:-$HOME/.local/share/research-sdd-tools/venv}"
  if [ -x "$PDF_VENV/bin/python" ] && rsdd_run_probe "$PDF_VENV/bin/python" -c 'import pymupdf4llm'; then
    printf '  %-22s AVAILABLE   %s\n' "pymupdf4llm" "$PDF_VENV/bin/python"
  else
    printf '  %-22s MISSING     (%s — extract-pdf.sh Tier 1)\n' "pymupdf4llm" "$PDF_VENV"
  fi
  row "ocrmypdf" ocrmypdf --version "$PDF_VENV/bin/ocrmypdf" "${BREW:+$BREW/bin/ocrmypdf}" /usr/bin/ocrmypdf
  python_row "marker" marker_single --help "$PDF_VENV/bin/marker_single" "${BREW:+$BREW/bin/marker_single}"
  python_row "docling" docling --help "$PDF_VENV/bin/docling" "${BREW:+$BREW/bin/docling}"
  echo ""
  echo "[ python bytecode ]"
  row "pycdc" pycdc --help "$HOME/dev/pycdc/pycdc"
  echo ""
  echo "[ dynamic / instrumentation ]"
  # frida-tools is a pipx/venv install → CLIs live in ~/.local/bin (see install-tool.sh frida).
  row "frida" frida --version "$HOME/.local/bin/frida" "${BREW:+$BREW/bin/frida}"
  row "frida-trace" frida-trace --version "$HOME/.local/bin/frida-trace" "${BREW:+$BREW/bin/frida-trace}"
  echo ""
  echo "Note: AVAILABLE means the resolver found the tool AND its bounded validation passed."
  echo "UNUSABLE means found but not runnable; MISSING means not detected."
}

OUT="$(report)"
printf '%s\n' "$OUT" > "$CACHE" 2>/dev/null || true
[ "$QUIET" -eq 1 ] || printf '%s\n' "$OUT"
[ "$QUIET" -eq 1 ] && echo "tool capability report cached → $CACHE"

# --require gate: evaluate after the report is produced so --quiet/--cache still work.
gate_rc=0
if [ -n "$REQUIRE" ]; then
  IFS=',' read -ra _req_list <<< "$REQUIRE"
  for _tool in "${_req_list[@]}"; do
    _label="$(require_label "$_tool")" || {
      printf '%s: --require: unknown tool "%s" — not in known set\n' \
        "$(basename "$0")" "$_tool" >&2
      exit 2
    }
    # grep -F treats label as literal string (handles parens in "Vineflower (jar)" etc.)
    _status="$(printf '%s\n' "$OUT" \
      | grep -F "  $_label " \
      | grep -oE 'AVAILABLE|UNUSABLE|MISSING|PROBE_FAILED' \
      | head -1 || true)"
    case "${_status:-}" in
      AVAILABLE)
        : ;;
      MISSING)
        printf 'REQUIRE FAILED [%s] MISSING — install it and re-run detect-tools.sh\n' \
          "$_tool" >&2
        gate_rc=1 ;;
      UNUSABLE)
        printf 'REQUIRE FAILED [%s] UNUSABLE — found but smoke test failed (present but broken is not usable)\n' \
          "$_tool" >&2
        gate_rc=1 ;;
      PROBE_FAILED)
        printf 'REQUIRE FAILED [%s] could not determine — probe failed (timeout or environment error); treating as unavailable\n' \
          "$_tool" >&2
        gate_rc=1 ;;
      *)
        printf 'REQUIRE FAILED [%s] — label "%s" not found in report (internal error)\n' \
          "$_tool" "$_label" >&2
        gate_rc=1 ;;
    esac
  done
fi
exit "$gate_rc"
