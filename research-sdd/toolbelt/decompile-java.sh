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
#     DEGRADED: ... units=N [primary=timeout|error|killed isolation=package|class]   rc 4  (all output present; some
#               units fell back, OR the whole-artifact primary run failed and isolation recovered it, OR the
#               timeout bound was unavailable)
#     PARTIAL:  ... units=N                                       rc 4  (some unit has NO output at all)
#     UNIT: <unit> reason=timeout|killed|error|empty|missing|marker|total_budget_exhausted
#                  fallback=<engine>|unavailable|none  result=ok|marked|kept-primary|failed
#       ok = fallback output in place · marked = the fallback output itself carries a failure marker ·
#       kept-primary = the marked primary output was kept (no usable fallback) · failed = NO output for the unit.
#   Isolation (jars): per package, then per unit (top-level class or orphan '$' class), then a coverage sweep;
#   an isolation time budget (RSDD_DECOMPILE_ISOLATE_BUDGET, default 1800 s, 0 = unlimited) falls back whole.
#   Failure markers are failure TEXTS only, anchored as comments; informational '$VF:' comments (synthetic
#   class, Extended synchronized range, finally-block / variable-type / multi-entry exception-range quality
#   notes) keep the primary file; comments saying the output is WRONG or will not compile ("decompiled code is
#   not correct", Invalid label, Made invalid labels) are failures.
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
ISOLATE_BUDGET="${RSDD_DECOMPILE_ISOLATE_BUDGET:-1800}"
KILL_AFTER="${RSDD_KILL_AFTER:-5}"
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
[[ "$ISOLATE_BUDGET" =~ ^[0-9]{1,6}$ ]] || { echo "invalid RSDD_DECOMPILE_ISOLATE_BUDGET (seconds, 0 = unlimited)" >&2; exit 2; }
[[ "$KILL_AFTER" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "invalid RSDD_KILL_AFTER" >&2; exit 2; }
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
    "$TIMEOUT_BIN" --kill-after="$KILL_AFTER" "$TIMEOUT" "${cmd[@]}" || rc=$?
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
declare -A HANDLED=() # units already recorded (the marker scan must not re-handle them)

# record_unit <unit> <reason> <fallback> <result> [note]
# result: ok (fallback output in place) · kept-primary (marked primary output kept, no usable fallback)
#         · failed (the unit has NO output).
record_unit() {
  UNITS+=("$1|$2|$3|$4|${5:-}")
  HANDLED["$1"]=1
  if [ "$4" = ok ] || [ "$4" = kept-primary ] || [ "$4" = marked ]; then DEGRADED_UNITS=$((DEGRADED_UNITS + 1)); else PARTIAL_UNITS=$((PARTIAL_UNITS + 1)); fi
}

# fallback_unit <unit> <reason> <input> [note] — decompile <input> with the fallback engine into $OUT.
fallback_unit() {
  local unit="$1" reason="$2" input="$3" note="${4:-}" tmp rc=0 failres=failed res mf
  [ "$reason" != marker ] || failres=kept-primary
  if [ "$FALLBACK" = none ]; then record_unit "$unit" "$reason" none "$failres" "$note"; return 0; fi
  tmp="$(mktemp -d -p "$WORK")"
  run_engine "$FALLBACK" "$input" "$tmp" || rc=$?
  if [ "$rc" -eq 3 ]; then
    record_unit "$unit" "$reason" unavailable "$failres" "$note"
  elif [ "$rc" -eq 0 ] && has_java "$tmp"; then
    cp -a "$tmp"/. "$OUT"/
    res=ok # a fallback whose OWN output carries a failure marker is not a success
    while IFS= read -r -d '' mf; do
      if file_has_marker "$mf"; then res=marked; break; fi
    done < <(find "$tmp" -type f -name '*.java' -print0)
    record_unit "$unit" "$reason" "$FALLBACK" "$res" "$note"
  else
    record_unit "$unit" "$reason" "$FALLBACK" "$failres" "$note"
  fi
}

unit_name() {
  local base
  base="$(basename "$IN")"
  case "${base,,}" in *.class) printf '%s\n' "${base%.[cC][lL][aA][sS][sS]}" ;; *) printf '%s\n' '<whole-artifact>' ;; esac
}

# reason_of <rc> — typed cause of a non-zero engine exit.
reason_of() { if [ "$1" -eq 124 ]; then echo timeout; elif [ "$1" -eq 137 ]; then echo killed; else echo error; fi; }

# Isolation time budget (typed total_budget_exhausted → whole-artifact fallback).
ISOLATE_T0=0
BUDGET_HIT=""
budget_exhausted() { [ "$ISOLATE_BUDGET" -gt 0 ] && [ $((SECONDS - ISOLATE_T0)) -ge "$ISOLATE_BUDGET" ]; }

# ── Unit isolation for jars (kit issue #1224) ────────────────────────────────
# A whole-jar failure must degrade ONLY the offending unit: re-run per package with the primary
# engine, and inside a failing package per top-level class; only a class that still fails falls back.
UNZIP_BIN="${RSDD_UNZIP_BIN:-unzip}"
EXT="$WORK/ext"
NO_SCAN=""
ISOLATION_LEVEL=""
PRIMARY_STATE=""
ISOLATION_WHY="" # set when isolation could not run (typed, reported on the unit)

# ensure_ext — extract the jar's classes once; fail (typed) when unzip is absent or the jar is unsafe.
ensure_ext() {
  [ -d "$EXT" ] && return 0
  if ! command -v "$UNZIP_BIN" >/dev/null 2>&1; then ISOLATION_WHY="isolation=unavailable"; return 1; fi
  mkdir -p "$EXT"
  "$UNZIP_BIN" -q -o "$IN" '*.class' -d "$EXT" >/dev/null 2>&1 || { rm -rf "$EXT"; ISOLATION_WHY="isolation=unavailable"; return 1; }
  # A jar must not smuggle symlinks into the scratch tree.
  if [ -n "$(find "$EXT" -type l -print -quit)" ]; then rm -rf "$EXT"; ISOLATION_WHY="isolation=unavailable"; return 1; fi
}

# is_unit_class <class-file> — a decompilation unit is a top-level class OR an orphan: a '$' class whose
# outer partner (the name up to its first '$') has no .class beside it (Scala Foo$, package$, obfuscated
# names, orphan inner classes). Every other '$' class is an inner class, emitted inside its outer's source.
is_unit_class() {
  local b o
  b="$(basename "$1" .class)"
  case "$b" in
    *'$'*) o="${b%%\$*}"; [ -n "$o" ] && [ -f "$(dirname "$1")/$o.class" ] && return 1 ;;
  esac
  return 0
}

# bisect_package <pkg> <idx> <reason> — per-unit primary runs for one failing package.
bisect_package() {
  local pkg="$1" idx="$2" reason="$3" f name cin cout crc k=0 unit
  local -a outer=()
  ISOLATION_LEVEL=class
  while IFS= read -r f; do is_unit_class "$f" && outer+=("$f"); done < <(find "$EXT/$pkg" -maxdepth 1 -name '*.class' | sort)
  for f in "${outer[@]+"${outer[@]}"}"; do
    if budget_exhausted; then BUDGET_HIT=1; return 0; fi
    name="$(basename "$f" .class)"; k=$((k + 1))
    unit="$name"; [ "$pkg" = . ] || unit="$pkg/$name"
    if [ "${#outer[@]}" -eq 1 ] && [ "$reason" != empty ]; then fallback_unit "$unit" "$reason" "$f"; continue; fi
    cin="$WORK/cin/$idx-$k"; cout="$WORK/cout/$idx-$k"; mkdir -p "$cin/$pkg"
    find "$EXT/$pkg" -maxdepth 1 \( -name "$name.class" -o -name "$name"'$*.class' \) -exec cp -p {} "$cin/$pkg/" \;
    crc=0; run_engine "$ENGINE" "$cin" "$cout" || crc=$?
    if [ "$crc" -eq 0 ] && has_java "$cout"; then cp -a "$cout"/. "$OUT"/
    elif [ "$crc" -eq 0 ]; then fallback_unit "$unit" empty "$f"
    else fallback_unit "$unit" "$(reason_of "$crc")" "$f"; fi
  done
}

# isolate_jar — package-level then class-level isolation, then a coverage sweep. Returns 1 when isolation is
# unavailable. ISOLATION_LEVEL records how deep isolation had to go (it is part of the typed summary).
isolate_jar() {
  ensure_ext || return 1
  local d pkg pin pout prc n=0 f unit
  ISOLATION_LEVEL=package
  ISOLATE_T0=$SECONDS
  while IFS= read -r d; do
    if budget_exhausted; then return 2; fi
    pkg="${d#"$EXT"}"; pkg="${pkg#/}"; [ -n "$pkg" ] || pkg=.
    n=$((n + 1)); pin="$WORK/pin/$n"; pout="$WORK/pout/$n"; mkdir -p "$pin/$pkg"
    find "$EXT/$pkg" -maxdepth 1 -name '*.class' -exec cp -p {} "$pin/$pkg/" \;
    prc=0; run_engine "$ENGINE" "$pin" "$pout" || prc=$?
    if [ "$prc" -eq 0 ] && has_java "$pout"; then
      cp -a "$pout"/. "$OUT"/
    elif [ "$prc" -eq 0 ]; then
      bisect_package "$pkg" "$n" empty # exit 0 with no source is never silently dropped
    else
      bisect_package "$pkg" "$n" "$(reason_of "$prc")"
    fi
    [ -z "$BUDGET_HIT" ] || return 2
  done < <(find "$EXT" -name '*.class' -printf '%h\n' | sort -u)
  # Coverage sweep: every unit class must be covered by output or by a UNIT line.
  while IFS= read -r f; do
    is_unit_class "$f" || continue
    unit="${f#"$EXT"/}"; unit="${unit%.class}"
    [ -f "$OUT/$unit.java" ] || [ -n "${HANDLED[$unit]:-}" ] || fallback_unit "$unit" missing "$f"
  done < <(find "$EXT" -name '*.class' | sort)
}

# ── Failure-marker scan (kit issue #1194) ────────────────────────────────────
# Vineflower writes "// $VF: Couldn't be decompiled" INDENTED inside the method body, so the pattern
# allows leading whitespace; only a comment-LEADING line counts (a trailing comment after code does not).
MARKER_RE='^[[:space:]]*(//|/\*+|\*)[[:space:]]*(\$VF: (Couldn.t be decompiled|Could not decompile|Unable to decompile|Failed to decompile|[^!]*decompiled code is not correct|Invalid label|Made invalid labels)|Unable to fully decompile class|Unable to fully structure code|This method has failed to decompile|This method could not be decompiled|Exception decompiling|COULD NOT DECOMPILE)'

# file_has_marker <file> — 0 when the file carries a failure marker; 1 none; 2 grep error.
file_has_marker() { local m=0; grep -qE "$MARKER_RE" "$1" 2>/dev/null || m=$?; return "$m"; }

# scan_markers — per-class fallback for every freshly written .java that carries a failure marker.
scan_markers() {
  local f rel unit input m
  while IFS= read -r -d '' f; do
    m=0; file_has_marker "$f" || m=$?
    [ "$m" -ne 1 ] || continue
    rel="${f#"$OUT"/}"; unit="${rel%.java}"
    [ -z "${HANDLED[$unit]:-}" ] || continue
    if [ "$m" -ne 0 ]; then record_unit "$unit" marker-scan-error none kept-primary; continue; fi
    if [[ "${IN,,}" == *.class ]]; then input="$IN"
    elif ensure_ext && [ -f "$EXT/$unit.class" ]; then input="$EXT/$unit.class"
    else record_unit "$unit" marker none kept-primary "${ISOLATION_WHY:-no-class-entry}"; continue; fi
    fallback_unit "$unit" marker "$input"
  done < <(find "$OUT" -type f -name '*.java' -newer "$STAMP" -print0)
}

rc=0
run_engine "$ENGINE" "$IN" "$OUT" || rc=$?
if [ "$rc" -ne 0 ]; then
  reason="$(reason_of "$rc")"
  PRIMARY_STATE="$reason"
  # A killed/failed run's partial output is untrustworthy: drop what this run wrote.
  find "$OUT" -type f -newer "$STAMP" -delete 2>/dev/null || true
  if [[ "${IN,,}" == *.jar ]]; then
    irc=0; isolate_jar || irc=$?
    if [ "$irc" -eq 1 ]; then
      NO_SCAN=1; fallback_unit "$(unit_name)" "$reason" "$IN" "$ISOLATION_WHY"
    elif [ "$irc" -eq 2 ]; then
      # Budget exhausted: discard the half-isolated state; the whole artifact falls back, typed.
      NO_SCAN=1; ISOLATION_LEVEL=""; UNITS=(); PARTIAL_UNITS=0; DEGRADED_UNITS=0; HANDLED=()
      find "$OUT" -type f -newer "$STAMP" -delete 2>/dev/null || true
      fallback_unit "$(unit_name)" total_budget_exhausted "$IN"
    fi
  else
    NO_SCAN=1 # whole-input fallback output is final: never re-scan (and re-fall-back) the fallback engine's files
    fallback_unit "$(unit_name)" "$reason" "$IN"
  fi
elif ! has_java "$OUT"; then
  # Verify the decompiler actually produced source: at least one .java file must exist in $OUT.
  # All three engines return 0 for obfuscated/empty/unsupported input without writing any source.
  echo "WARN: $ENGINE decompiler exited 0 but produced no .java files in $OUT (input may be obfuscated or unsupported)" >&2
  exit 1
fi
[ -n "$NO_SCAN" ] || scan_markers

# Typed result. OK only when no unit fell back and no probe was degraded.
if [ "${#UNITS[@]}" -eq 0 ] && [ -z "$PROBE_DEGRADED" ] && [ -z "$PRIMARY_STATE" ]; then
  echo "OK: $IN -> $OUT  (engine=$ENGINE)"
  exit 0
fi
status=DEGRADED
[ "$PARTIAL_UNITS" -eq 0 ] || status=PARTIAL
detail="units=${#UNITS[@]}"
[ -z "$PRIMARY_STATE" ] || detail="$detail primary=$PRIMARY_STATE${ISOLATION_LEVEL:+ isolation=$ISOLATION_LEVEL}"
[ -z "$PROBE_DEGRADED" ] || detail="$detail reason=$PROBE_DEGRADED"
echo "$status: $IN -> $OUT  (engine=$ENGINE $detail)"
for u in "${UNITS[@]+"${UNITS[@]}"}"; do
  IFS='|' read -r uname ureason ufb ures unote <<<"$u"
  echo "UNIT: $uname reason=$ureason fallback=$ufb result=$ures${unote:+ $unote}"
done
has_java "$OUT" || { echo "WARN: no .java files produced in $OUT" >&2; exit 1; }
exit 4
