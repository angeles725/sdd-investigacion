#!/usr/bin/env bash
# decompile-java.sh — decompiles a Java .jar / .class to source.
# Preference: Vineflower (best output) -> CFR -> Procyon. javap for exact signatures.
#
# Usage:
#   decompile-java.sh <in.jar|in.class> <out-dir> [--engine vineflower|cfr|procyon] [--jar path] [--thread-count N]
#   decompile-java.sh --javap <Class.class>      # signatures + bytecode (javap -p -c)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
# Resolved relative to this wrapper at runtime.
# shellcheck disable=SC1091
source "$HERE/lib/tool-env.sh"

JAVA_HOME="$(rsdd_resolve_java_home)" || {
  echo "Java 21 not usable (set JAVA_HOME or RESEARCH_SDD_JAVA_HOME)" >&2
  exit 3
}
canonical_launcher() {
  local launcher="$1"
  local resolved
  resolved="$(readlink -f -- "$launcher")" || return 1
  [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}
JAVA="$(canonical_launcher "$JAVA_HOME/bin/java")" || {
  echo "Java launcher is not a canonical executable" >&2
  exit 3
}

if [ "${1:-}" = "--javap" ]; then
  JAVAP="$(canonical_launcher "$JAVA_HOME/bin/javap")" || {
    echo "javap launcher is not a canonical executable" >&2
    exit 3
  }
  exec "$JAVAP" -p -c "${2:?clase requerida}"
fi

IN="${1:?usage: decompile-java.sh <in.jar|in.class> <out-dir> [--engine ...]}"
OUT="${2:?out-dir required}"
ENGINE="vineflower"
JAR_OVERRIDE=""
THREAD_COUNT=""
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:?engine required}"; shift 2 ;;
    --jar) JAR_OVERRIDE="${2:?jar required}"; shift 2 ;;
    --thread-count)
      THREAD_COUNT="${2:?thread count required}"
      [[ "$THREAD_COUNT" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "invalid thread count" >&2; exit 2; }
      shift 2
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
JAVA_ARGS=()
if [ -n "${RSDD_DECOMPILE_MAX_HEAP:-}" ]; then
  [[ "$RSDD_DECOMPILE_MAX_HEAP" =~ ^[1-9][0-9]{0,5}[mMgG]$ ]] || { echo "invalid RSDD_DECOMPILE_MAX_HEAP" >&2; exit 2; }
  JAVA_ARGS=("-Xmx$RSDD_DECOMPILE_MAX_HEAP")
fi
mkdir -p "$OUT"

case "$ENGINE" in
  vineflower)
    VINEFLOWER="${JAR_OVERRIDE:-$(rsdd_resolve_java_jar vineflower)}" || { echo "Vineflower jar not found (set VINEFLOWER_JAR)" >&2; exit 3; }
    [ -f "$VINEFLOWER" ] || { echo "Vineflower jar not found" >&2; exit 3; }
    VINEFLOWER_ARGS=()
    [ -z "$THREAD_COUNT" ] || VINEFLOWER_ARGS=("--thread-count=$THREAD_COUNT")
    "$JAVA" "${JAVA_ARGS[@]}" -jar "$VINEFLOWER" "${VINEFLOWER_ARGS[@]}" "$IN" "$OUT"
    ;;
  cfr)
    CFR="${JAR_OVERRIDE:-$(rsdd_resolve_java_jar cfr)}" || { echo "CFR jar not found (set CFR_JAR)" >&2; exit 3; }
    [ -f "$CFR" ] || { echo "CFR jar not found" >&2; exit 3; }
    "$JAVA" "${JAVA_ARGS[@]}" -jar "$CFR" "$IN" --outputdir "$OUT"
    ;;
  procyon)
    PROCYON="${JAR_OVERRIDE:-$(rsdd_resolve_java_jar procyon)}" || { echo "Procyon jar not found (set PROCYON_JAR)" >&2; exit 3; }
    [ -f "$PROCYON" ] || { echo "Procyon jar not found" >&2; exit 3; }
    if [[ "${IN,,}" == *.jar ]]; then
      "$JAVA" "${JAVA_ARGS[@]}" -jar "$PROCYON" -jar "$IN" -o "$OUT"
    else
      "$JAVA" "${JAVA_ARGS[@]}" -jar "$PROCYON" -o "$OUT" "$IN"
    fi
    ;;
  *) echo "unknown engine: $ENGINE (use vineflower|cfr|procyon)" >&2; exit 2 ;;
esac
# Verify the decompiler actually produced source: at least one .java file must exist in $OUT.
# All three engines return 0 for obfuscated/empty/unsupported input without writing any source.
find "$OUT" -type f -name '*.java' -print -quit | grep -q . || { echo "WARN: $ENGINE decompiler exited 0 but produced no .java files in $OUT (input may be obfuscated or unsupported)" >&2; exit 1; }
echo "OK: $IN -> $OUT  (engine=$ENGINE)"
