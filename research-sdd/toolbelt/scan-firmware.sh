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
    # Ported to Go: `rsdd corroborate carve` (the carve is no longer Python-backed).
    # RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
    _rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
    while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
    if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
    _RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
    . "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
    rsdd_exec corroborate carve --input "${2:?file}" --output "${3:?new-out-dir}" "${@:4}"
    ;;
  scan)
    command -v binwalk >/dev/null || { echo "binwalk not installed" >&2; exit 3; }
    binwalk -E "${2:?file}" 2>/dev/null | head -5 || { _sp="${PIPESTATUS[0]}"; [ "$_sp" -eq 0 ] || [ "$_sp" -eq 141 ] || { echo "binwalk entropy scan failed (rc=$_sp): $2" >&2; exit "$_sp"; }; }   # entropy
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
