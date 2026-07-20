#!/usr/bin/env bash
# Deterministic, non-executing SootUp JVM call-graph exporter.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
source "$HERE/lib/tool-env.sh"
MODULE="$HERE/jvm-callgraph"
JAR="$MODULE/target/jvm-callgraph.jar"

JAVA_HOME="$(rsdd_resolve_java_home)" || {
  echo "jvm-callgraph: Java 21 not usable (set JAVA_HOME or RESEARCH_SDD_JAVA_HOME)" >&2
  exit 3
}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

build() {
  command -v mvn >/dev/null 2>&1 || { echo "jvm-callgraph: Maven not found" >&2; exit 3; }
  (cd "$MODULE" && mvn -o -B -ntp package)
}

bootstrap() {
  command -v mvn >/dev/null 2>&1 || { echo "jvm-callgraph: Maven not found" >&2; exit 3; }
  echo "jvm-callgraph: fetching pinned dependencies/plugins from Maven Central" >&2
  (cd "$MODULE" && mvn -s "$MODULE/maven-central-settings.xml" -B -ntp \
    org.apache.maven.plugins:maven-dependency-plugin:3.7.0:go-offline package)
}

analyze() {
  [ -f "$JAR" ] || { echo "jvm-callgraph: analyzer missing; run '$0 build'" >&2; exit 3; }
  local seconds="${RSDD_JVM_CALLGRAPH_TIMEOUT:-120}"
  local heap="${RSDD_JVM_CALLGRAPH_MAX_HEAP:-1024m}"
  [[ "$seconds" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "jvm-callgraph: invalid RSDD_JVM_CALLGRAPH_TIMEOUT" >&2; exit 2; }
  [[ "$heap" =~ ^[1-9][0-9]{0,5}[mMgG]$ ]] || { echo "jvm-callgraph: invalid RSDD_JVM_CALLGRAPH_MAX_HEAP" >&2; exit 2; }
  local timeout_bin
  timeout_bin="$(command -v timeout)" || { echo "jvm-callgraph: timeout command not found" >&2; exit 3; }
  unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
  exec "$timeout_bin" --signal=TERM --kill-after=5 "${seconds}s" \
    "$JAVA_HOME/bin/java" -Xms64m "-Xmx$heap" -jar "$JAR" "$@"
}

case "${1:-}" in
  build) shift; [ "$#" -eq 0 ] || { echo "usage: $0 build" >&2; exit 2; }; build ;;
  bootstrap) shift; [ "$#" -eq 0 ] || { echo "usage: $0 bootstrap" >&2; exit 2; }; bootstrap ;;
  analyze) shift; analyze "$@" ;;
  *) echo "usage: $0 {build|bootstrap|analyze [options]}" >&2; exit 2 ;;
esac
