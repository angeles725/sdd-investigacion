#!/usr/bin/env bash
# profile-target.sh — classifies a research target's artifacts and suggests
# the appropriate decompilation/analysis wrapper. READ-ONLY: only inspects.
#
# Usage:  profile-target.sh <target-path> [--max N]
# Output: "file  type  suggested wrapper" table + summary per type.
set -euo pipefail

TARGET="${1:-}"
MAX=400
[ "${2:-}" = "--max" ] && MAX="${3:-400}"

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "usage: $0 <target-path> [--max N]" >&2
  exit 2
fi

suggest() {
  # $1 = output of `file`; prints the suggested wrapper
  case "$1" in
    *"Java class"*|*"Java archive"*)            echo "decompile-java.sh" ;;
    *"Zip archive"*)                            echo "decompile-java.sh (if .jar)" ;;
    *".Net assembly"*|*"Mono/.Net"*)            echo "decompile-net.sh" ;;
    *"ELF "*executable*|*"ELF "*shared*)        echo "decompile-native.sh" ;;
    *"PE32"*|*"PE32+"*|*"MS Windows"*)          echo "decompile-net.sh? / decompile-native.sh" ;;
    *"PDF document"*)                           echo "fetch-doc.sh (extract text/OCR)" ;;
    *"firmware"*|*"filesystem"*|*"data"*)       echo "scan-firmware.sh" ;;
    *)                                          echo "(revisar manual)" ;;
  esac
}

echo "== Perfilado de $TARGET =="
declare -A COUNT
n=0
while IFS= read -r f; do
  [ "$n" -ge "$MAX" ] && { echo "... (corte en $MAX; subí con --max)"; break; }
  ft="$(file -b "$f" 2>/dev/null || echo unknown)"
  w="$(suggest "$ft")"
  key="${w%% *}"
  COUNT["$key"]=$(( ${COUNT["$key"]:-0} + 1 ))
  printf "%-50s | %-32s | %s\n" "${f#"$TARGET"/}" "${ft:0:32}" "$w"
  n=$((n+1))
done < <(find "$TARGET" -type f \
            \( -iname '*.jar' -o -iname '*.class' -o -iname '*.dll' -o -iname '*.exe' \
               -o -iname '*.so' -o -iname '*.bin' -o -iname '*.pdf' -o -iname '*.fw' \) \
            2>/dev/null | sort)

echo ""
echo "== Resumen por wrapper sugerido =="
for k in "${!COUNT[@]}"; do printf "  %-40s %s\n" "$k" "${COUNT[$k]}"; done
[ "$n" -eq 0 ] && echo "  (no binaries/PDF detected — source-code target? use direct reading + CodeGraph)"
