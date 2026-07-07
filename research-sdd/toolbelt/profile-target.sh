#!/usr/bin/env bash
# profile-target.sh — classifies a research target's artifacts and suggests
# the appropriate decompilation/analysis wrapper. READ-ONLY: only inspects.
#
# Usage:  profile-target.sh <target-path> [--max N]
# Env:    EXTRA_EXT="scfx scf pak"   # extra target-specific extensions to scan
# Output: "file  type  suggested wrapper" table + summary per type.
#
# Robust to proprietary containers: scans a broad extension allowlist (incl.
# firmware/container formats) AND falls back to magic-byte heuristics for files
# that `file` reports as generic `data` — so an 81MB `.scfx` is never silently skipped.
set -euo pipefail

TARGET="${1:-}"
MAX=400
[ "${2:-}" = "--max" ] && MAX="${3:-400}"

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "usage: $0 <target-path> [--max N]   (env: EXTRA_EXT=\"ext1 ext2\")" >&2
  exit 2
fi

# Base extension allowlist + firmware/container/proprietary + caller-supplied EXTRA_EXT.
BASE_EXT="jar class dll exe so bin pdf fw img rom hex dat scfx scf pak bundle apk ipa cab iso"
ALL_EXT="$BASE_EXT ${EXTRA_EXT:-}"
FIND_ARGS=()
for e in $ALL_EXT; do FIND_ARGS+=(-iname "*.$e" -o); done
FIND_ARGS+=(-false)   # close the -o chain

magic() { xxd -l 8 "$1" 2>/dev/null | awk '{$1="";print}' | tr -s ' '; }

suggest() {
  # $1 = output of `file`, $2 = path; prints the suggested wrapper
  case "$1" in
    *"Java class"*|*"Java archive"*)            echo "decompile-java.sh" ;;
    *"Zip archive"*)                            echo "decompile-java.sh (if .jar)" ;;
    *".Net assembly"*|*"Mono/.Net"*)            echo "decompile-net.sh" ;;
    *"ELF "*executable*|*"ELF "*shared*)        echo "decompile-native.sh" ;;
    *"PE32"*|*"MS Windows"*)                    echo "decompile-net.sh? / decompile-native.sh" ;;
    *"PDF document"*)                           echo "fetch-doc.sh (extract text/OCR)" ;;
    *"firmware"*|*"filesystem"*)                echo "scan-firmware.sh" ;;
    *"data"*|*"empty"*)                         echo "scan-firmware.sh + MANUAL (opaque/custom container; magic: $(magic "$2"))" ;;
    *)                                          echo "scan-firmware.sh + MANUAL (magic: $(magic "$2"))" ;;
  esac
}

echo "== Profiling $TARGET =="
declare -A COUNT
n=0
while IFS= read -r f; do
  [ "$n" -ge "$MAX" ] && { echo "... (cut at $MAX; raise with --max)"; break; }
  ft="$(file -b "$f" 2>/dev/null || echo unknown)"
  w="$(suggest "$ft" "$f")"
  key="${w%% *}"
  COUNT["$key"]=$(( ${COUNT["$key"]:-0} + 1 ))
  printf "%-46s | %-26s | %s\n" "${f#"$TARGET"/}" "${ft:0:26}" "$w"
  n=$((n+1))
done < <(find "$TARGET" -type f \( "${FIND_ARGS[@]}" \) 2>/dev/null | sort)

echo ""
echo "== Summary by suggested wrapper =="
for k in "${!COUNT[@]}"; do printf "  %-26s %s\n" "$k" "${COUNT[$k]}"; done
if [ "$n" -eq 0 ]; then
  echo "  (no known binaries/PDF detected by extension — source-code target? use direct reading + CodeGraph)"
  echo "  Tip: if the central artifact has an unlisted extension, re-run with EXTRA_EXT=\"<ext>\"."
fi
