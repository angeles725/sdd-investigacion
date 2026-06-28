#!/usr/bin/env bash
# decompile-java.sh — decompiles a Java .jar / .class to source.
# Preference: Vineflower (best output) -> CFR -> Procyon. javap for exact signatures.
#
# Usage:
#   decompile-java.sh <in.jar|in.class> <out-dir> [--engine vineflower|cfr|procyon]
#   decompile-java.sh --javap <Class.class>      # signatures + bytecode (javap -p -c)
set -euo pipefail

JAVA_HOME="${JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
VINEFLOWER="${VINEFLOWER:-/home/cristian/modules/Prototipos/Reflow/vineflower.jar}"
CFR="${CFR:-/home/cristian/modules/Prototipos/Reflow/cfr.jar}"
PROCYON="${PROCYON:-/home/cristian/modules/Prototipos/modulos/procyon.jar}"

if [ "${1:-}" = "--javap" ]; then
  exec "$JAVA_HOME/bin/javap" -p -c "${2:?clase requerida}"
fi

IN="${1:?usage: decompile-java.sh <in.jar|in.class> <out-dir> [--engine ...]}"
OUT="${2:?out-dir required}"
ENGINE="vineflower"
[ "${3:-}" = "--engine" ] && ENGINE="${4:-vineflower}"
mkdir -p "$OUT"

case "$ENGINE" in
  vineflower) "$JAVA" -jar "$VINEFLOWER" "$IN" "$OUT" ;;
  cfr)        "$JAVA" -jar "$CFR" "$IN" --outputdir "$OUT" ;;
  procyon)    "$JAVA" -jar "$PROCYON" -jar "$IN" -o "$OUT" 2>/dev/null \
                || "$JAVA" -jar "$PROCYON" "$IN" -o "$OUT" ;;
  *) echo "unknown engine: $ENGINE (use vineflower|cfr|procyon)" >&2; exit 2 ;;
esac
echo "OK: $IN -> $OUT  (engine=$ENGINE)"
