#!/usr/bin/env bash
# scan-firmware.sh — triage of firmware / opaque binaries.
# binwalk for structure + yara to locate known routines/signatures.
#
# Usage:
#   scan-firmware.sh scan    <file>                    # binwalk (entropy + signatures)
#   scan-firmware.sh carve   <file> <new-out-dir>      # validated exact byte ranges
#   scan-firmware.sh evidence <file> <new-out-dir>     # bounded static evidence
#   scan-firmware.sh yara     <rules.yar> <file>       # YARA signature match
set -euo pipefail

MODE="${1:?usage: scan-firmware.sh scan|carve|evidence|yara ...}"
case "$MODE" in
  evidence)
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$HERE/corroborate-firmware.sh" --input "${2:?file}" --output "${3:?new-out-dir}"
    ;;
  carve)
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec python3 "$HERE/firmware_carve.py" --input "${2:?file}" --output "${3:?new-out-dir}" "${@:4}"
    ;;
  scan)
    command -v binwalk >/dev/null || { echo "binwalk not installed" >&2; exit 3; }
    binwalk -E "${2:?file}" 2>/dev/null | head -5 || true   # entropy
    binwalk "${2:?file}"                                     # signatures/sections
    ;;
  extract)
    echo "extract was removed because legacy extraction was unsafe; use 'carve <file> <new-out-dir>' for validated byte carving" >&2
    exit 2
    ;;
  yara)
    command -v yara >/dev/null || { echo "yara not installed" >&2; exit 3; }
    yara -s "${2:?rules.yar}" "${3:?file}"
    ;;
  *) echo "unknown mode: $MODE (carve|evidence|scan|yara)" >&2; exit 2 ;;
esac
