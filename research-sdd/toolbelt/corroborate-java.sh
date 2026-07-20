#!/usr/bin/env bash
# Bounded multi-engine Java corroboration; analyzed classes are never executed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
# Resolved relative to this wrapper at runtime.
# shellcheck disable=SC1091
source "$HERE/lib/tool-env.sh"

JAVA_HOME="$(rsdd_resolve_java_home)" || {
  echo "corroborate-java: Java 21 not usable" >&2; exit 3;
}
export JAVA_HOME
resolve_adapter() {
  local name="$1"
  local jar
  jar="$(rsdd_resolve_java_jar "$name" || true)"
  [ -n "$jar" ] && rsdd_probe_java_jar "$name" "$jar" && printf '%s\n' "$jar"
}
RSDD_CORROBORATE_VINEFLOWER="$(resolve_adapter vineflower || true)"
RSDD_CORROBORATE_CFR="$(resolve_adapter cfr || true)"
RSDD_CORROBORATE_PROCYON="$(resolve_adapter procyon || true)"
export RSDD_CORROBORATE_VINEFLOWER RSDD_CORROBORATE_CFR RSDD_CORROBORATE_PROCYON
exec python3 "$HERE/corroborate_java.py" \
  --decompile-wrapper "${RSDD_DECOMPILE_WRAPPER:-$HERE/decompile-java.sh}" \
  --manifest-module "$HERE/analysis_manifest.py" "$@"
