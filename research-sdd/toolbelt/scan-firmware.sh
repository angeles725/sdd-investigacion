#!/usr/bin/env bash
# scan-firmware.sh — triage of firmware / opaque binaries.
# binwalk for structure/extraction + yara to locate known routines/signatures.
#
# Usage:
#   scan-firmware.sh scan    <file>                    # binwalk (entropy + signatures)
#   scan-firmware.sh extract <file> <out-dir>          # binwalk -e (extracts)
#   scan-firmware.sh yara    <rules.yar> <file>        # YARA signature match
set -euo pipefail

MODE="${1:?usage: scan-firmware.sh scan|extract|yara ...}"
case "$MODE" in
  scan)
    command -v binwalk >/dev/null || { echo "binwalk not installed" >&2; exit 3; }
    binwalk -E "${2:?file}" 2>/dev/null | head -5 || true   # entropy
    binwalk "${2:?file}"                                     # signatures/sections
    ;;
  extract)
    command -v binwalk >/dev/null || { echo "binwalk not installed" >&2; exit 3; }
    OUT="${3:?out-dir}"; mkdir -p "$OUT"
    ( cd "$OUT" && binwalk -e --run-as=root "${2:?file}" 2>/dev/null \
        || binwalk -e "${2:?file}" )
    echo "OK: extraído en $OUT"
    ;;
  yara)
    command -v yara >/dev/null || { echo "yara not installed" >&2; exit 3; }
    yara -s "${2:?rules.yar}" "${3:?file}"
    ;;
  *) echo "unknown mode: $MODE (scan|extract|yara)" >&2; exit 2 ;;
esac
