#!/usr/bin/env bash
# java-fidelity-experiment.sh — the reproducible experiment to run BEFORE restating a tool-behaviour rule
# about Java decompilation fidelity (kit issue #1488, code half of #1215; METHODOLOGY §11b "Run an
# experiment before restating a tool-behavior rule").
#
# Usage:
#   java-fidelity-experiment.sh [--fixtures DIR] [--work DIR]
#     --fixtures DIR  directory of small synthetic fixtures, one top-level class per <Name>.java in the
#                     default package, each compiling to EXACTLY one .class (default:
#                     tests/fixtures/java-fidelity-experiment next to this script)
#     --work DIR      scratch directory (default: a mktemp dir removed on exit)
#   Env overrides: RSDD_FIDELITY_JAVAC, RSDD_FIDELITY_JAVAP (default: PATH lookup),
#                  RSDD_FIDELITY_DECOMPILER (default: decompile-java.sh next to this script).
#
# Design decision (recorded here and in METHODOLOGY §11b): the experiment does NOT call a decompiler
# directly. It goes through the kit's own wrapper (decompile-java.sh: Vineflower, CFR/Procyon fallback), so
# the verdict describes what the kit's pipeline preserves, not what one engine could do in isolation.
# The wrapper's combined output is captured per cell (dec.log): its exit status types the cell and its status
# line ("(engine=<e>)") feeds the engine provenance; the rest (the JDK module scan log) is not interpreted.
#
# What it does, per fixture and per mode (g = javac -g, nog = javac with no -g flag):
#   1. javac the fixture;   2. decompile the .class with the wrapper;   3. recompile the decompiled .java
#   with the same javac flags;   4. compare `javap -c -p` of the original and recompiled class, constant-pool
#   indices (#N or #N, #M) and the "Compiled from" line removed (everything else, including instruction
#   offsets, must match).   Verdicts (one line per cell):
#     FIDELITY <Name> mode=<g|nog> verdict=GOOD       recompiles, normalised bytecode identical
#     FIDELITY <Name> mode=<g|nog> verdict=DIVERGED   recompiles, bytecode differs (a finding, not a failure)
#     FIDELITY <Name> mode=<g|nog> verdict=FAILED reason=<compile|multi-class|decompile|no-output|
#                                        multi-output|timeout|recompile|recompile-no-class|javap-original|
#                                        javap-recompiled>
#   Plus one DEBUGINFO line per fixture: whether `javap -l -p` shows a LocalVariableTable with -g and
#   without it (the "-g vs no -g" half of the matrix).
#   (DEBUGINFO values: yes | no | unmeasured — unmeasured means the original did not compile or javap failed.)
#   Summary: RESULT: DONE jdk=<v|unknown> engines=<e[,e]|unknown> engine_degraded_cells=N [timeout=unavailable]
#                         constructs=N cells=M good=a diverged=b failed=c
#   engines= is the engine name the wrapper's own status line reported per cell (the ENGINE VERSION is not
#   exposed by the wrapper and is not recorded); engine_degraded_cells counts wrapper exit 4 (fallback ran).
#   Every such cell also prints `FALLBACK <Name> mode=<g|nog> engine=<e|unknown>` before its verdict, so a
#   verdict produced by a fallback engine is attributable to its cell (engines= alone is a union).
#
# Exit codes (anti-silent-zero, CLAUDE.md §7 — three states stay distinguishable):
#   0  experiment ran; every cell measured (DIVERGED / FAILED cells are findings, read the lines)
#   1  fixtures directory exists but holds no *.java (empty-input, nothing was measured)
#   2  usage error or fixtures directory absent
#   4  DEGRADED: a runtime dependency is missing, nothing is reported as measured. One line:
#        DEGRADED: reason=javac-missing|javap-missing|decompiler-missing [detail]
#      A DEGRADED run never prints a verdict for the cell that could not run and never prints RESULT: DONE.
#
# Env: RSDD_FIDELITY_TIMEOUT (positive integer seconds, default 720; anything else exits 2) is the OUTER bound on
#      each wrapper run (typed FAILED reason=timeout). The wrapper bounds its primary engine at 240 s
#      (RSDD_DECOMPILE_TIMEOUT) and then runs a fallback engine, so the outer bound is deliberately larger:
#      an equal bound would kill the wrapper mid-fallback and hide the fallback behind reason=timeout.
#
# Limits (stated, not hidden): GOOD means "same bytecode for this fixture on this JDK and this engine
# version", not "faithful in general"; one construct per fixture, default package only; the experiment
# says nothing about an engine the wrapper did not run; a cell the wrapper completed through its fallback
# engine is counted and named (FALLBACK line); the wrapper labels such a run with its PRIMARY engine, so for
# those cells the verdict covers a mix of primary and fallback output (see dec.log).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HERE/tests/fixtures/java-fidelity-experiment"
WORK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fixtures) [ $# -ge 2 ] || { echo "usage: --fixtures needs a directory" >&2; exit 2; }; FIXTURES="$2"; shift 2 ;;
    --work)     [ $# -ge 2 ] || { echo "usage: --work needs a directory" >&2; exit 2; }; WORK="$2"; shift 2 ;;
    -h|--help)  sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) echo "usage: java-fidelity-experiment.sh [--fixtures DIR] [--work DIR]" >&2; exit 2 ;;
  esac
done

[ -d "$FIXTURES" ] || { echo "fixtures directory not found: $FIXTURES" >&2; exit 2; }
mapfile -t SRCS < <(find "$FIXTURES" -maxdepth 1 -type f -name '*.java' | sort)
if [ "${#SRCS[@]}" -eq 0 ]; then
  echo "no fixtures: $FIXTURES holds no *.java (nothing measured)" >&2
  exit 1  # SENTINEL-EMPTY-FIXTURES
fi

# ---- runtime dependency probe -> typed DEGRADED ----------------------------------------------------------
JAVAC_BIN="${RSDD_FIDELITY_JAVAC:-}"
[ -n "$JAVAC_BIN" ] || JAVAC_BIN="$(command -v javac 2>/dev/null)"
JAVAP_BIN="${RSDD_FIDELITY_JAVAP:-}"
[ -n "$JAVAP_BIN" ] || JAVAP_BIN="$(command -v javap 2>/dev/null)"
DECOMPILER="${RSDD_FIDELITY_DECOMPILER:-$HERE/decompile-java.sh}"

# A DEGRADED exit after some cells were already printed says so: those lines are valid, the run is incomplete.
degraded() {
  local done_cells=$(( ${n_good:-0} + ${n_div:-0} + ${n_fail:-0} ))
  if [ "$done_cells" -gt 0 ]; then
    echo "DEGRADED: reason=$1 ${2:-} partial_cells=$done_cells (FIDELITY lines above are valid; the run is INCOMPLETE, no RESULT line)"
  else
    echo "DEGRADED: reason=$1 ${2:-}"
  fi
  exit 4
}
if ! { [ -f "$JAVAC_BIN" ] && [ -x "$JAVAC_BIN" ]; }  # SENTINEL-JAVAC-PROBE
then degraded javac-missing "(no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)"; fi
{ [ -f "$JAVAP_BIN" ] && [ -x "$JAVAP_BIN" ]; } || degraded javap-missing "(no usable javap; set RSDD_FIDELITY_JAVAP or put a JDK on PATH)"
{ [ -f "$DECOMPILER" ] && [ -x "$DECOMPILER" ]; } || degraded decompiler-missing "($DECOMPILER is not executable)"

if [ -z "$WORK" ]; then
  WORK="$(mktemp -d)" || { echo "cannot create a scratch directory" >&2; exit 2; }
  trap 'rm -rf "$WORK"' EXIT
else
  mkdir -p "$WORK" || { echo "cannot create --work directory: $WORK" >&2; exit 2; }
fi

# javac -version prints "javac <ver>" (possibly after JVM notices such as JAVA_TOOL_OPTIONS); take the
# first line of that shape, else "unknown" — never a guessed value.
JDK_VERSION="unknown"
while IFS= read -r _l; do
  case "$_l" in "javac "[0-9]*) JDK_VERSION="${_l#javac }"; break ;; esac
done < <("$JAVAC_BIN" -version 2>&1)

# Bound every decompiler run: the OUTER guard, larger than the wrapper's own 240 s primary bound (see header).
TIMEOUT_SECS="${RSDD_FIDELITY_TIMEOUT-720}"
[[ "$TIMEOUT_SECS" =~ ^[1-9][0-9]{0,5}$ ]]  # SENTINEL-TIMEOUT-VALIDATE
[ $? -eq 0 ] || { echo "usage: RSDD_FIDELITY_TIMEOUT must be a positive integer (seconds), got '$TIMEOUT_SECS'" >&2; exit 2; }
TIMEOUT_BIN="$(command -v timeout 2>/dev/null)"
[ -n "$TIMEOUT_BIN" ] || TIMEOUT_BIN="$(command -v gtimeout 2>/dev/null)"
TIMEOUT_NOTE=""; [ -n "$TIMEOUT_BIN" ] || TIMEOUT_NOTE=" timeout=unavailable"
ENGINES=""; n_engine_degraded=0

# normalise FILE: strip constant-pool references ("#7", "#7, 3" - javap -c prints them per instruction and
# they shift with unrelated pool order) and the "Compiled from" header (names the .java, which differs).
# Everything else, including instruction offsets and branch targets, stays and must match.
normalise() { sed -E 's/#[0-9]+(, *[0-9]+)?//g; /^Compiled from/d' "$1"; }
n_good=0; n_div=0; n_fail=0

verdict() { # verdict NAME MODE VERDICT [REASON]
  printf 'FIDELITY %s mode=%s verdict=%s%s\n' "$1" "$2" "$3" "${4:+ reason=$4}"
  case "$3" in GOOD) n_good=$((n_good+1)) ;; DIVERGED) n_div=$((n_div+1)) ;; *) n_fail=$((n_fail+1)) ;; esac
}

cell() { # cell NAME SRC MODE FLAGS
  local name="$1" src="$2" mode="$3" flags="$4"
  local base="$WORK/$name/$mode" log orig re dec jf n_cls n_java drc eng
  rm -rf "$base"; mkdir -p "$base/orig" "$base/dec" "$base/re"
  orig="$base/orig"; dec="$base/dec"; re="$base/re"; log="$base/log"
  # shellcheck disable=SC2086
  if ! "$JAVAC_BIN" $flags -d "$orig" "$src" >"$log" 2>&1; then verdict "$name" "$mode" FAILED compile; return; fi
  n_cls="$(find "$orig" -name '*.class' -type f | wc -l)"
  if [ "$n_cls" -ne 1 ]; then verdict "$name" "$mode" FAILED multi-class; return; fi
  local cls; cls="$(find "$orig" -name '*.class' -type f)"
  drc=0
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$TIMEOUT_SECS" "$DECOMPILER" "$cls" "$dec" >"$base/dec.log" 2>&1 || drc=$?
  else "$DECOMPILER" "$cls" "$dec" >"$base/dec.log" 2>&1 || drc=$?; fi
  # Engine provenance: the wrapper's status line carries "(engine=<e>)" on rc 0 and "(engine=<e> <detail>)" on
  # a degraded rc 4 run; both shapes are read (the label is the wrapper's primary engine, see header).
  eng="$(sed -n 's/.*(engine=\([A-Za-z0-9_.-]*\)[ )].*/\1/p' "$base/dec.log" | tail -n 1)"
  # A cell whose wrapper run printed no engine line (failed, timed out) adds nothing; no engine at all -> unknown.
  if [ -n "$eng" ]; then
    case ",$ENGINES," in *",$eng,"*) ;; *) ENGINES="${ENGINES:+$ENGINES,}$eng" ;; esac
  fi
  fb_note() { n_engine_degraded=$((n_engine_degraded+1)); printf 'FALLBACK %s mode=%s engine=%s\n' "$name" "$mode" "${eng:-unknown}"; }
  [ "$drc" -ne 4 ] || fb_note  # SENTINEL-FALLBACK-NOTE
  if [ "$drc" -eq 3 ]  # SENTINEL-DECOMPILER-RC3
  then degraded decompiler-missing "(decompiler exit 3 on $name mode=$mode: required tool missing)"; fi
  if [ "$drc" -eq 124 ]  # SENTINEL-TIMEOUT-RC
then verdict "$name" "$mode" FAILED timeout; return; fi
  if [ "$drc" -ne 0 ] && [ "$drc" -ne 4 ]; then verdict "$name" "$mode" FAILED decompile; return; fi
  n_java="$(find "$dec" -name '*.java' -type f | wc -l)"
  if [ "$n_java" -eq 0 ]  # SENTINEL-NO-OUTPUT
  then verdict "$name" "$mode" FAILED no-output; return; fi
  if [ "$n_java" -gt 1 ]; then verdict "$name" "$mode" FAILED multi-output; return; fi
  jf="$(find "$dec" -name '*.java' -type f)"
  # shellcheck disable=SC2086
  if ! "$JAVAC_BIN" $flags -d "$re" "$jf" >"$log" 2>&1; then  # SENTINEL-RECOMPILE-RC
    verdict "$name" "$mode" FAILED recompile; return
  fi
  local rcls; rcls="$(find "$re" -name "$(basename "$cls")" -type f)"
  [ -n "$rcls" ] || { verdict "$name" "$mode" FAILED recompile-no-class; return; }
  "$JAVAP_BIN" -c -p "$cls" >"$base/orig.javap" 2>&1 || { verdict "$name" "$mode" FAILED javap-original; return; }
  "$JAVAP_BIN" -c -p "$rcls" >"$base/re.javap" 2>&1 || { verdict "$name" "$mode" FAILED javap-recompiled; return; }
  local orig_norm new_norm
  orig_norm="$(normalise "$base/orig.javap")"; new_norm="$(normalise "$base/re.javap")"
  if [ "$orig_norm" = "$new_norm" ]  # SENTINEL-COMPARE
  then verdict "$name" "$mode" GOOD; else verdict "$name" "$mode" DIVERGED; fi
}

# lvt_present NAME MODE -> yes | no | unmeasured. "unmeasured" = the original did not compile or javap failed,
# so absence of a LocalVariableTable was never observed (it must not read as "no").
lvt_present() {
  local d="$WORK/$1/$2/orig" cls out="$WORK/$1/$2/lvt.javap" n=0
  : >"$out"
  while IFS= read -r cls; do
    "$JAVAP_BIN" -l -p "$cls" >>"$out" 2>&1 || { echo unmeasured; return; }
    n=$((n+1))
  done < <(find "$d" -name '*.class' -type f | sort)
  [ "$n" -gt 0 ] || { echo unmeasured; return; }  # SENTINEL-LVT-UNMEASURED
  if grep -q 'LocalVariableTable' "$out"; then echo yes; else echo no; fi
}

for src in "${SRCS[@]}"; do
  name="$(basename "$src" .java)"
  g_flag="-g"  # SENTINEL-G-FLAG
  cell "$name" "$src" g "$g_flag"
  cell "$name" "$src" nog ""
  printf 'DEBUGINFO %s g_lvt=%s nog_lvt=%s\n' "$name" "$(lvt_present "$name" g)" "$(lvt_present "$name" nog)"
done

printf 'RESULT: DONE jdk=%s engines=%s engine_degraded_cells=%d%s constructs=%d cells=%d good=%d diverged=%d failed=%d\n' \
  "$JDK_VERSION" "${ENGINES:-unknown}" "$n_engine_degraded" "$TIMEOUT_NOTE" "${#SRCS[@]}" $((n_good + n_div + n_fail)) "$n_good" "$n_div" "$n_fail"
exit 0
