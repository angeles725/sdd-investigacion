#!/usr/bin/env bash
# Ported to Go: `rsdd corroborate java`. Compatibility shim (removed in phase 8, kit issue #2275).
# It keeps the environment contract the engine reads: JAVA_HOME and the three probed adapter JARs.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
HERE="$_RSDD_SELF"
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
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec corroborate java \
  --decompile-wrapper "${RSDD_DECOMPILE_WRAPPER:-$HERE/decompile-java.sh}" \
  --manifest-module "$HERE/analysis_manifest.py" "$@"
