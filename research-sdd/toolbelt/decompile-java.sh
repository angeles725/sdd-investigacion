#!/usr/bin/env bash
# decompile-java.sh — decompiles a Java .jar / .class to source.
# Preference: Vineflower (best output) -> CFR -> Procyon. javap for exact signatures.
#
# Usage:
#   decompile-java.sh <in.jar|in.class> <out-dir> [--engine vineflower|cfr|procyon] [--jar path]
#                     [--thread-count N] [--timeout SECONDS] [--fallback-engine cfr|procyon|vineflower|none]
#   decompile-java.sh --javap <Class.class>      # signatures + bytecode (javap -p -c)
#
# Bounded timeout + automatic fallback (kit issues #1190, #1224):
#   The primary engine runs under `timeout` (default 240 s, RSDD_DECOMPILE_TIMEOUT or --timeout; 0 = unbounded).
#   On timeout or non-zero exit the affected UNIT falls back to the fallback engine (default: cfr; procyon when
#   the primary is cfr). A top-level OK is printed ONLY when every unit was decompiled by the primary engine.
#   Otherwise one typed status line is printed, followed by one UNIT line per affected unit:
#     OK:       <in> -> <out>  (engine=<e>)                       rc 0
#     DEGRADED: ... units=N                                       rc 4  (all output present; some units fell back,
#                                                                       or the timeout bound was unavailable)
#     PARTIAL:  ... units=N                                       rc 4  (some unit has NO output at all)
#     UNIT: <unit> reason=timeout|error|marker fallback=<engine>|unavailable result=ok|failed
#   Absent tool / timeout / error / empty output are distinct: exit 3 = required tool missing, exit 1 = no .java
#   produced at all, exit 4 = typed degraded/partial result, reason= names the cause per unit.
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
TIMEOUT="${RSDD_DECOMPILE_TIMEOUT:-240}"
FALLBACK=""
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:?engine required}"; shift 2 ;;
    --jar) JAR_OVERRIDE="${2:?jar required}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?timeout required}"; shift 2 ;;
    --fallback-engine) FALLBACK="${2:?fallback engine required}"; shift 2 ;;
    --thread-count)
      THREAD_COUNT="${2:?thread count required}"
      [[ "$THREAD_COUNT" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "invalid thread count" >&2; exit 2; }
      shift 2
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]{1,6}$ ]] || { echo "invalid timeout (seconds, 0 = unbounded)" >&2; exit 2; }
case "$ENGINE" in vineflower | cfr | procyon) ;; *) echo "unknown engine: $ENGINE (use vineflower|cfr|procyon)" >&2; exit 2 ;; esac
if [ -z "$FALLBACK" ]; then
  if [ "$ENGINE" = cfr ]; then FALLBACK=procyon; else FALLBACK=cfr; fi
fi
case "$FALLBACK" in vineflower | cfr | procyon | none) ;; *) echo "unknown fallback engine: $FALLBACK" >&2; exit 2 ;; esac
JAVA_ARGS=()
if [ -n "${RSDD_DECOMPILE_MAX_HEAP:-}" ]; then
  [[ "$RSDD_DECOMPILE_MAX_HEAP" =~ ^[1-9][0-9]{0,5}[mMgG]$ ]] || { echo "invalid RSDD_DECOMPILE_MAX_HEAP" >&2; exit 2; }
  JAVA_ARGS=("-Xmx$RSDD_DECOMPILE_MAX_HEAP")
fi
mkdir -p "$OUT"

# Runtime-dependency probe (kit CLAUDE.md §7): `timeout` absent is a typed degraded state, never a
# silent unbounded run presented as OK.
TIMEOUT_BIN="${RSDD_TIMEOUT_BIN:-timeout}"
PROBE_DEGRADED=""
if [ "$TIMEOUT" -gt 0 ] && ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
  PROBE_DEGRADED="timeout-unavailable"
  echo "WARN: '$TIMEOUT_BIN' not found; engines run UNBOUNDED (typed degraded)" >&2
  TIMEOUT=0
fi

# engine_jar <engine> -> prints the resolved jar. The --jar override applies to the PRIMARY engine only.
engine_jar() {
  local e="$1"
  if [ -n "$JAR_OVERRIDE" ] && [ "$e" = "$ENGINE" ]; then printf '%s\n' "$JAR_OVERRIDE"; return 0; fi
  rsdd_resolve_java_jar "$e"
}

# run_engine <engine> <input> <outdir> — one bounded engine invocation.
# rc: 0 ok · 124 timeout · 3 engine jar unavailable · other = engine exit code.
run_engine() {
  local e="$1" in="$2" out="$3" jar rc=0
  local -a cmd
  jar="$(engine_jar "$e")" || return 3
  [ -f "$jar" ] || return 3
  case "$e" in
    vineflower)
      local -a va=()
      [ -z "$THREAD_COUNT" ] || va=("--thread-count=$THREAD_COUNT")
      cmd=("$JAVA" "${JAVA_ARGS[@]}" -jar "$jar" "${va[@]}" "$in" "$out") ;;
    cfr) cmd=("$JAVA" "${JAVA_ARGS[@]}" -jar "$jar" "$in" --outputdir "$out") ;;
    procyon)
      if [[ "${in,,}" == *.jar ]]; then
        cmd=("$JAVA" "${JAVA_ARGS[@]}" -jar "$jar" -jar "$in" -o "$out")
      else
        cmd=("$JAVA" "${JAVA_ARGS[@]}" -jar "$jar" -o "$out" "$in")
      fi ;;
  esac
  mkdir -p "$out"
  if [ "$TIMEOUT" -gt 0 ]; then
    "$TIMEOUT_BIN" --kill-after=5 "$TIMEOUT" "${cmd[@]}" || rc=$?
  else
    "${cmd[@]}" || rc=$?
  fi
  return "$rc"
}

# has_java <dir> — at least one .java file exists below it.
has_java() { find "$1" -type f -name '*.java' -print -quit 2>/dev/null | grep -q .; }

# Fail fast (exit 3, as before) when the PRIMARY engine cannot run at all.
PRIMARY_JAR="$(engine_jar "$ENGINE")" && [ -f "$PRIMARY_JAR" ] || {
  echo "$ENGINE jar not found (set $(printf '%s' "$ENGINE" | tr '[:lower:]' '[:upper:]')_JAR)" >&2
  exit 3
}

STAMP="$(mktemp)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$STAMP" "$WORK"; }
trap cleanup EXIT

UNITS=()        # one line per affected unit: "<unit>|<reason>|<fallback>|<result>"
PARTIAL_UNITS=0 # units that ended with NO output
DEGRADED_UNITS=0

# record_unit <unit> <reason> <fallback> <result>
record_unit() {
  UNITS+=("$1|$2|$3|$4")
  if [ "$4" = ok ]; then DEGRADED_UNITS=$((DEGRADED_UNITS + 1)); else PARTIAL_UNITS=$((PARTIAL_UNITS + 1)); fi
}

# fallback_unit <unit> <reason> <input> — decompile <input> with the fallback engine into $OUT.
fallback_unit() {
  local unit="$1" reason="$2" input="$3" tmp rc=0
  if [ "$FALLBACK" = none ]; then record_unit "$unit" "$reason" none failed; return 0; fi
  tmp="$(mktemp -d -p "$WORK")"
  run_engine "$FALLBACK" "$input" "$tmp" || rc=$?
  if [ "$rc" -eq 3 ]; then
    record_unit "$unit" "$reason" unavailable failed
  elif [ "$rc" -eq 0 ] && has_java "$tmp"; then
    cp -a "$tmp"/. "$OUT"/
    record_unit "$unit" "$reason" "$FALLBACK" ok
  else
    record_unit "$unit" "$reason" "$FALLBACK" failed
  fi
}

unit_name() {
  local base
  base="$(basename "$IN")"
  case "${base,,}" in *.class) printf '%s\n' "${base%.[cC][lL][aA][sS][sS]}" ;; *) printf '%s\n' '<whole-artifact>' ;; esac
}

rc=0
run_engine "$ENGINE" "$IN" "$OUT" || rc=$?
if [ "$rc" -ne 0 ]; then
  reason=error
  [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && reason=timeout
  # A killed/failed run's partial output is untrustworthy: drop what this run wrote.
  find "$OUT" -type f -newer "$STAMP" -delete 2>/dev/null || true
  fallback_unit "$(unit_name)" "$reason" "$IN"
elif ! has_java "$OUT"; then
  # Verify the decompiler actually produced source: at least one .java file must exist in $OUT.
  # All three engines return 0 for obfuscated/empty/unsupported input without writing any source.
  echo "WARN: $ENGINE decompiler exited 0 but produced no .java files in $OUT (input may be obfuscated or unsupported)" >&2
  exit 1
fi

# Typed result. OK only when no unit fell back and no probe was degraded.
if [ "${#UNITS[@]}" -eq 0 ] && [ -z "$PROBE_DEGRADED" ]; then
  echo "OK: $IN -> $OUT  (engine=$ENGINE)"
  exit 0
fi
status=DEGRADED
[ "$PARTIAL_UNITS" -eq 0 ] || status=PARTIAL
detail="units=${#UNITS[@]}"
[ -z "$PROBE_DEGRADED" ] || detail="$detail reason=$PROBE_DEGRADED"
echo "$status: $IN -> $OUT  (engine=$ENGINE $detail)"
for u in "${UNITS[@]+"${UNITS[@]}"}"; do
  IFS='|' read -r uname ureason ufb ures <<<"$u"
  echo "UNIT: $uname reason=$ureason fallback=$ufb result=$ures"
done
has_java "$OUT" || { echo "WARN: no .java files produced in $OUT" >&2; exit 1; }
exit 4
