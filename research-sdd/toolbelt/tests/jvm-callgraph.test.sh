#!/usr/bin/env bash
# tests/jvm-callgraph.test.sh — jvm-callgraph lane-aware test suite
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based structural assertions; NO java/mvn spawn required.
#                    Always runs.  Anti-#128 WIN.
#   slow           — real java/mvn build + full integration tests.
#                    Skips with informational message when java 21+ or mvn absent.
#   all            — both lanes.
#
# R2 EXCEPTION (WEAKEST-TEETH LANE): no importable Python SUT oracle exists —
#   the entire SUT is Main.java (Java-only; zero .py files in the pipeline).
#   Fast-lane --prove-teeth mutations operate on COPIES OF FIXTURES (mutate the
#   JSON, confirm the structural assertion catches the dishonest fixture).
#   This is fixture-copy teeth that prove the ASSERTION bites, NOT that a live
#   SUT regression is caught.
#   ANTI-#128 CREDIT: fast lane claims ZERO anti-#128 isolation credit.
#   Real SUT-regression teeth (mutate Main.java + rebuild; StageCopyProbe calling
#   Main.verifyStaged) stay SLOW-only.
#
# Anti-#128 fix: BOTH whole-suite SKIPs are DELETED from the original suite.
#   Deleted skip 1: Java-21 gate (old lines 13-21) emitting 0/0 and exit 0.
#   Deleted skip 2: Maven gate (old lines 22-27) emitting 0/0 and exit 0.
#   FAST lane always runs, always emits a real pass/fail count, never 0/0.
#   SLOW lane emits an informational message when java 21+ or mvn absent and
#   skips the slow-lane tests only — NOT the whole suite.
#
# Exit 2 when SUT shell wrapper is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
WRAPPER="$TOOLBELT/jvm-callgraph.sh"

# Source lane helper (aborts on invalid RSDD_TEST_LANE value per §7 anti-silent-zero).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the SUT shell wrapper does not exist yet.
[ -f "$WRAPPER" ] || { echo "FATAL: SUT not found: $WRAPPER" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
# One EXIT trap for both temp dirs (a later `trap` would REPLACE this one): the slow lane's ROOT
# and the --prove-teeth _MUT are both created later and both start empty.
ROOT=""; _MUT=""
_cleanup(){ [ -z "$ROOT" ] || rm -rf -- "$ROOT"; [ -z "$_MUT" ] || rm -rf -- "$_MUT"; }
trap _cleanup EXIT

# Active lane (aborts on invalid RSDD_TEST_LANE value).
_lane="$(rsdd_lane)"

# Fixture paths (cwd-independent; existence validated in the fast-lane section).
_FIX_HAPPY="$(rsdd_lane_fixture jvm-callgraph happy)"
_FIX_CAPPED="$(rsdd_lane_fixture jvm-callgraph capped)"

_slow_skip=1  # default; set to 0 only when slow lane actually runs
# Every case that needs the built analyzer jar: the single list a bootstrap-absent SKIP iterates.
_ANALYZER_CASES=(S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13)

# ---------------------------------------------------------------------------
# SLOW LANE — real java/mvn build + integration tests
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then
  _slow_skip=0

  # Resolve Java home via shared helper.
  # shellcheck source=../lib/tool-env.sh
  source "$TOOLBELT/lib/tool-env.sh"
  # shellcheck source=lib/jvm-offline-probe.sh
  source "$HERE/lib/jvm-offline-probe.sh"
  _JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"
  _JAVAC_MAJOR="$([ -x "${_JAVA21:-}/bin/javac" ] && \
    "$_JAVA21/bin/javac" -version 2>&1 | grep -oE '[0-9]+' | head -1 || echo 0)"

  if [ -z "${_JAVA21:-}" ] || [ ! -x "${_JAVA21:-}/bin/javac" ] \
      || [ "${_JAVAC_MAJOR:-0}" -lt 21 ]; then
    echo "SLOW lane: java 21+ not found (major=${_JAVAC_MAJOR:-0}); slow-lane tests skipped." >&2
    _slow_skip=1
  elif ! command -v mvn >/dev/null 2>&1; then
    echo "SLOW lane: mvn not found; slow-lane tests skipped." >&2
    _slow_skip=1
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"   # removed by the single _cleanup EXIT trap installed above
    JAVA21="$_JAVA21"
    run(){ "$WRAPPER" analyze "$@"; }

    # S1: offline Maven build
    if "$WRAPPER" build >"$ROOT/build.log" 2>&1; then
      ok "S1: offline Java 21 Maven build"
    elif _verdict="$(rsdd_jvm_build_verdict)"; [[ "$_verdict" == skip:* ]]; then
      # The host never ran `jvm-callgraph.sh bootstrap` (needs network): no maven-compiler-plugin
      # artifact in the local Maven repo is tagged with the bootstrap mirror id from
      # maven-central-settings.xml (tests/lib/jvm-offline-probe.sh; the verdict comes from the
      # environment, never from the build log). Typed SKIP, one line per analyzer case, so
      # run-all's skipped total is exact. S9/S10/S12 would otherwise "fail closed" vacuously on a
      # missing jar (analyzer-missing exit 3). Never a FAIL and never a silent pass (#1588).
      for _c in "${_ANALYZER_CASES[@]}"; do
        printf '  SKIP  %s analyzer case: bootstrap absent (%s); run jvm-callgraph.sh bootstrap\n' "$_c" "${_verdict#skip: }"
      done
      _slow_skip=1
    else
      # Bootstrap present (or the probe could not look) and the build still fails: a real defect.
      no "S1: offline Java 21 Maven build [$_verdict] $(tail -5 "$ROOT/build.log")"
    fi
  fi # S1 gate

  if [[ "$_slow_skip" -eq 0 ]]; then
    # Build fixture jar (App→Router→Transform→Sink chain).
    # App has a side-effecting static initialiser that writes MARKER if the class is
    # loaded at runtime; the CHA analysis must never execute the fixture.
    mkdir -p "$ROOT/src/fixture" "$ROOT/classes"
    MARKER="$ROOT/FIXTURE_EXECUTED"
    cat > "$ROOT/src/fixture/App.java" <<JAVA
package fixture;
import java.nio.file.*;
public final class App {
  static { try { Files.writeString(Path.of("$MARKER"), "executed"); } catch (Exception e) { throw new RuntimeException(e); } }
  public static void main(String[] args) { Router.route(args.length); }
}
JAVA
    cat > "$ROOT/src/fixture/Router.java" <<'JAVA'
package fixture; final class Router { static void route(int value) { Transform.normalize(value); } }
JAVA
    cat > "$ROOT/src/fixture/Transform.java" <<'JAVA'
package fixture; final class Transform { static void normalize(int value) { Sink.write(Integer.toString(value)); } }
JAVA
    cat > "$ROOT/src/fixture/Sink.java" <<'JAVA'
package fixture; final class Sink { static void write(String value) { System.out.println(value); } }
JAVA
    "$JAVA21/bin/javac" --release 21 -d "$ROOT/classes" "$ROOT"/src/fixture/*.java
    "$JAVA21/bin/jar" --create --file "$ROOT/fixture.jar" -C "$ROOT/classes" .
    COMMON=(--input "$ROOT/fixture.jar" --sink-contains "fixture.Sink: void write" \
            --max-depth 8 --max-paths 10 --max-nodes 100 --max-edges 100 --max-xrefs 100)

    # S2: determinism + never-executes
    if run "${COMMON[@]}" --output "$ROOT/a.json" \
        && run "${COMMON[@]}" --output "$ROOT/b.json" \
        && cmp -s "$ROOT/a.json" "$ROOT/b.json" \
        && [ ! -e "$MARKER" ]; then
      ok "S2: main discovery is deterministic and never executes fixture"
    else
      no "S2: main discovery is deterministic and never executes fixture"
    fi

    # S3: JSON contract (schema, entries, xrefs, paths, components, runtime, completeness)
    if python3 - "$ROOT/a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "jvm-callgraph.v1" and d["algorithm"] == "CHA"
assert d["entries"] == ["<fixture.App: void main(java.lang.String[])>"]
assert d["reverse_xrefs"] == [{"callers": ["<fixture.Transform: void normalize(int)>"],
    "sink": "<fixture.Sink: void write(java.lang.String)>"}]
assert d["paths"][0]["methods"] == [
    "<fixture.App: void main(java.lang.String[])>",
    "<fixture.Router: void route(int)>",
    "<fixture.Transform: void normalize(int)>",
    "<fixture.Sink: void write(java.lang.String)>"]
assert d["tool"]["components"] == [
    "org.soot-oss:sootup.callgraph:2.0.0",
    "org.soot-oss:sootup.java.bytecode.frontend:2.0.0"]
assert d["runtime"]["major"] >= 21 and d["errors"] == [] and d["completeness"] == "partial"
PY
    then ok "S3: JSON contract (schema, entries, xrefs, paths, components, runtime, completeness)"
    else no "S3: JSON contract"; fi

    # S4: exact entry signature
    ENTRY='<fixture.App: void main(java.lang.String[])>'
    if run --input "$ROOT/fixture.jar" --entry "$ENTRY" \
        --sink-contains "fixture.Sink: void write" --output "$ROOT/explicit.json"; then
      ok "S4: exact entry signature"
    else no "S4: exact entry signature"; fi

    # S5: missing entry fails closed
    if ! run --input "$ROOT/fixture.jar" \
          --entry '<fixture.Missing: void main(java.lang.String[])>' \
          --output "$ROOT/missing.json" 2>"$ROOT/missing.err" \
        && grep -q 'entry method not found' "$ROOT/missing.err"; then
      ok "S5: missing entry fails closed"
    else no "S5: missing entry fails closed"; fi

    # S6: omitted entry fails when no main
    "$JAVA21/bin/jar" --create --file "$ROOT/no-main.jar" -C "$ROOT/classes" fixture/Sink.class
    if ! run --input "$ROOT/no-main.jar" --output "$ROOT/no-main.json" \
          2>"$ROOT/no-main.err" \
        && grep -q 'no application main method found' "$ROOT/no-main.err"; then
      ok "S6: omitted entry fails when no main exists"
    else no "S6: omitted entry fails when no main exists"; fi

    # S7: depth and output caps explicit — TIGHTENED from original any(truncated) theater.
    # Deliberate fix: the original asserted any(d["truncated"].values()), which stays
    # GREEN if only one specific flag is flipped wrong. This asserts named flags so
    # each is independently verifiable and the fixture-copy prove-teeth mutation fires RED.
    if run --input "$ROOT/fixture.jar" --sink-contains fixture \
          --max-depth 1 --max-paths 1 --max-nodes 1 --max-edges 1 --max-xrefs 1 \
          --output "$ROOT/capped.json" \
        && python3 - "$ROOT/capped.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
trunc = d["truncated"]
# nodes=True: 4 CHA graph nodes > max-nodes=1
assert trunc["nodes"] is True, f"nodes={trunc['nodes']!r}"
# edges=True: 3 CHA graph edges > max-edges=1
assert trunc["edges"] is True, f"edges={trunc['edges']!r}"
# xrefs=True: callers across fixture sinks exceed max-xrefs=1
assert trunc["xrefs"] is True, f"xrefs={trunc['xrefs']!r}"
# paths=True: 2 paths found (App→App self, App→Router) but max-paths=1
assert trunc["paths"] is True, f"paths={trunc['paths']!r}"
PY
    then ok "S7: depth and output caps are explicit (specific truncated flags)"
    else no "S7: depth and output caps are explicit"; fi

    # S8: output collision requires overwrite
    if ! run "${COMMON[@]}" --output "$ROOT/a.json" 2>/dev/null \
        && run "${COMMON[@]}" --output "$ROOT/a.json" --overwrite; then
      ok "S8: output collision requires overwrite"
    else no "S8: output collision requires overwrite"; fi

    # S9: output cannot overwrite analyzed input
    if ! run --input "$ROOT/fixture.jar" --output "$ROOT/fixture.jar" \
          --overwrite 2>/dev/null; then
      ok "S9: output cannot overwrite analyzed input"
    else no "S9: output cannot overwrite analyzed input"; fi

    # S10: unsafe files, duplicate options, and invalid caps fail closed
    ln -s "$ROOT/fixture.jar" "$ROOT/link.jar"
    if ! run --input "$ROOT/link.jar" --output "$ROOT/link.json" 2>/dev/null \
        && ! run --input "$ROOT/fixture.jar" --input "$ROOT/fixture.jar" \
             --output "$ROOT/dup.json" 2>/dev/null \
        && ! run --input "$ROOT/fixture.jar" --max-depth 0 \
             --output "$ROOT/bad-cap.json" 2>/dev/null; then
      ok "S10: unsafe files, duplicate options, and invalid caps fail closed"
    else no "S10: unsafe files, duplicate options, and invalid caps fail closed"; fi

    # S11: unresolved totals remain complete above emission cap
    mkdir -p "$ROOT/many-src/many" "$ROOT/many-classes"
    {
      echo 'package many; final class Missing {'
      for n in $(seq 0 100); do echo "static void m$n() {}"; done
      echo '}'
    } > "$ROOT/many-src/many/Missing.java"
    {
      echo 'package many; public final class AppMany { public static void main(String[] args) {'
      for n in $(seq 0 100); do echo "Missing.m$n();"; done
      echo '} }'
    } > "$ROOT/many-src/many/AppMany.java"
    "$JAVA21/bin/javac" --release 21 -d "$ROOT/many-classes" \
      "$ROOT"/many-src/many/*.java
    "$JAVA21/bin/jar" --create --file "$ROOT/many.jar" \
      -C "$ROOT/many-classes" many/AppMany.class
    if run --input "$ROOT/many.jar" --output "$ROOT/many.json" \
        && python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
c = d["counts"]
assert c["unresolved_total"] > 100
assert c["unresolved_emitted"] == len(d["unresolved"]) == 100
assert d["truncated"]["unresolved"]
' "$ROOT/many.json"; then
      ok "S11: unresolved totals remain complete above emission cap"
    else no "S11: unresolved totals remain complete above emission cap"; fi

    # S12: ancestor symlink cannot alias output to input
    mkdir -p "$ROOT/real/sub"
    cp "$ROOT/fixture.jar" "$ROOT/real/sub/evidence.jar"
    ln -s "$ROOT/real" "$ROOT/alias"
    before="$(sha256sum "$ROOT/real/sub/evidence.jar")"
    if ! run --input "$ROOT/real/sub/evidence.jar" \
          --output "$ROOT/alias/sub/evidence.jar" --overwrite 2>/dev/null \
        && [ "$(sha256sum "$ROOT/real/sub/evidence.jar")" = "$before" ]; then
      ok "S12: ancestor symlink cannot alias output to input"
    else no "S12: ancestor symlink cannot alias output to input"; fi

    # S13: StageCopyProbe — changed private copy is rejected before graph construction
    mkdir -p "$ROOT/stage-probe-src/researchsdd/callgraph" \
             "$ROOT/stage-probe-classes"
    cat > "$ROOT/stage-probe-src/researchsdd/callgraph/StageCopyProbe.java" <<'JAVA'
package researchsdd.callgraph;
import java.nio.file.Files;
import java.nio.file.Path;
public final class StageCopyProbe {
  public static void main(String[] args) throws Exception {
    Main.FileIdentity expected = new Main.FileIdentity(
        "original.jar", Long.parseLong(args[1]), args[2]);
    try {
      Main.verifyStaged(expected, Path.of(args[0]), "input");
    } catch (RuntimeException rejected) {
      if (rejected.getMessage().contains("private staged input identity mismatch")) return;
      throw rejected;
    }
    Files.writeString(Path.of(args[3]), "graph construction reached");
    throw new AssertionError("changed private copy was accepted");
  }
}
JAVA
    "$JAVA21/bin/javac" --release 21 \
      -cp "$HERE/../jvm-callgraph/target/jvm-callgraph.jar" \
      -d "$ROOT/stage-probe-classes" \
      "$ROOT/stage-probe-src/researchsdd/callgraph/StageCopyProbe.java"
    if "$JAVA21/bin/java" \
        -cp "$HERE/../jvm-callgraph/target/jvm-callgraph.jar:$ROOT/stage-probe-classes" \
        researchsdd.callgraph.StageCopyProbe \
        "$ROOT/no-main.jar" \
        "$(stat -c %s "$ROOT/fixture.jar")" \
        "$(sha256sum "$ROOT/fixture.jar" | cut -d' ' -f1)" \
        "$ROOT/GRAPH_CONSTRUCTED" \
        && [ ! -e "$ROOT/GRAPH_CONSTRUCTED" ]; then
      ok "S13: changed private copy is rejected before graph construction"
    else no "S13: changed private copy is rejected before graph construction"; fi

  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based structural assertions (R2 EXCEPTION: no Python oracle)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: both fixtures must exist before asserting.
  for _fix in "$_FIX_HAPPY" "$_FIX_CAPPED"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite jvm-callgraph" >&2
      exit 1
    fi
  done

  # F1: schema, algorithm, tool.components, completeness, errors.
  # completeness is hardcoded "partial" in Main.java — assert exact string.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "jvm-callgraph.v1", \
    f"F1: schema={d.get('schema')!r}"
assert d.get("algorithm") == "CHA", \
    f"F1: algorithm={d.get('algorithm')!r}"
assert d.get("tool", {}).get("components") == [
    "org.soot-oss:sootup.callgraph:2.0.0",
    "org.soot-oss:sootup.java.bytecode.frontend:2.0.0"], \
    f"F1: tool.components={d.get('tool', {}).get('components')!r}"
assert d.get("completeness") == "partial", \
    f"F1: completeness={d.get('completeness')!r} (hardcoded in Main.java)"
assert d.get("errors") == [], \
    f"F1: errors={d.get('errors')!r}"
print(f"OK: schema=jvm-callgraph.v1 algorithm=CHA completeness=partial errors=[]")
PY
  then ok "F1: happy fixture: schema, algorithm, tool.components, completeness=partial, errors=[]"
  else no "F1: happy fixture structural assertions"; fi

  # F2: entries, reverse_xrefs, paths[0].methods chain.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("entries") == ["<fixture.App: void main(java.lang.String[])>"], \
    f"F2: entries={d.get('entries')!r}"
assert d.get("reverse_xrefs") == [{
    "callers": ["<fixture.Transform: void normalize(int)>"],
    "sink": "<fixture.Sink: void write(java.lang.String)>"}], \
    f"F2: reverse_xrefs={d.get('reverse_xrefs')!r}"
paths = d.get("paths", [])
assert len(paths) >= 1, f"F2: no paths in fixture"
assert paths[0].get("methods") == [
    "<fixture.App: void main(java.lang.String[])>",
    "<fixture.Router: void route(int)>",
    "<fixture.Transform: void normalize(int)>",
    "<fixture.Sink: void write(java.lang.String)>"], \
    f"F2: paths[0].methods={paths[0].get('methods')!r}"
print(f"OK: entries=[App.main] xrefs=[Transform->Sink] path=4-method chain")
PY
  then ok "F2: happy fixture: entries, reverse_xrefs, paths[0].methods chain"
  else no "F2: happy fixture entries/xrefs/paths assertions"; fi

  # F3: runtime.major >= 21 (range check — value is the actual int from regen machine;
  # not asserted exact because different JDKs produce 21/26/etc, all are valid).
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
major = d.get("runtime", {}).get("major")
assert isinstance(major, int), f"F3: runtime.major is not int: {major!r}"
assert major >= 21, f"F3: runtime.major={major!r} (expected >= 21)"
print(f"OK: runtime.major={major} >= 21")
PY
  then ok "F3: happy fixture: runtime.major >= 21 (range check, not exact)"
  else no "F3: happy fixture runtime.major range assertion"; fi

  # F4: capped fixture — specific truncated flags (tightened from any() theater).
  # Deliberate fix: the original asserted any(d["truncated"].values()) which stays
  # GREEN even if one specific flag is flipped wrong (other True flags keep any()=True).
  # This asserts each affected flag by name so a single wrong value fires RED.
  # Flag rationale with --max-depth 1 --max-paths 1 --max-nodes 1 --max-edges 1 --max-xrefs 1:
  #   nodes=True:  4 CHA graph nodes emitted > max-nodes=1
  #   edges=True:  3 CHA graph edges emitted > max-edges=1
  #   xrefs=True:  callers-across-fixture-sinks exceed max-xrefs=1
  #   paths=True:  2 paths found (App->App self, App->Router) but max-paths=1
  if python3 - "$_FIX_CAPPED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
trunc = d.get("truncated", {})
# nodes=True: 4 CHA graph nodes > max-nodes=1
assert trunc.get("nodes") is True, \
    f"F4: truncated.nodes={trunc.get('nodes')!r} (expected True: 4 nodes > max 1)"
# edges=True: 3 CHA graph edges > max-edges=1
assert trunc.get("edges") is True, \
    f"F4: truncated.edges={trunc.get('edges')!r} (expected True: 3 edges > max 1)"
# xrefs=True: callers across fixture sinks exceed max-xrefs=1
assert trunc.get("xrefs") is True, \
    f"F4: truncated.xrefs={trunc.get('xrefs')!r} (expected True: callers > max-xrefs 1)"
# paths=True: 2 paths found (App->App self, App->Router) but max-paths=1 caps at 1
assert trunc.get("paths") is True, \
    f"F4: truncated.paths={trunc.get('paths')!r} (expected True: 2 paths found but max 1)"
print(f"OK: nodes={trunc['nodes']} edges={trunc['edges']} xrefs={trunc['xrefs']} paths={trunc['paths']}")
PY
  then ok "F4: capped fixture: truncated.nodes/edges/xrefs/paths all True (specific, not any())"
  else no "F4: capped fixture specific truncated flag assertions"; fi

fi # fast | all

# ---------------------------------------------------------------------------
# --prove-teeth: fixture-copy mutation controls (R2 EXCEPTION — no live SUT import).
# These prove the ASSERTION bites by mutating a fixture copy, NOT by mutating the SUT.
# Fast lane claims ZERO anti-#128 isolation credit (see header).
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: jvm-callgraph fixture-copy mutation controls (R2 EXCEPTION) --"
  echo "-- Fixture-copy teeth: assertions bite on dishonest fixture; no live SUT import --"
  # lib/mutant.sh is sourced only on this path; every helper the controls call is probed.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_built mutant_tooth || exit 2
  # The SUT of these controls is a JSON fixture: skip the `bash -n` check (the builder below
  # round-trips through json, and a mutant that is not valid JSON crashes the checker, which the
  # --bad-lacks guard refuses to read as a bite).
  # (scoped per call in mk() below, never exported: #1814)
  _MUT="$(mktemp -d)"   # removed by the single _cleanup EXIT trap installed above

  mk(){ MUTANT_SYNTAX=none mutant_built "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

  # Builder: set one dotted key of a fixture copy, refusing (rc 2) unless the key currently holds
  # the expected OLD value (JSON), so a changed fixture cannot turn the mutation into a no-op.
  # args: SRC OUT KEYPATH OLD_JSON NEW_JSON
  _BUILD='
import json, sys, pathlib
src, out, path, old, new = sys.argv[1:6]
d = json.load(open(src)); keys = path.split("."); t = d
for k in keys[:-1]:
    t = t[k]
if t.get(keys[-1]) != json.loads(old):
    print("MUTANT-SETUP-FAIL: %s is %r, expected %s" % (path, t.get(keys[-1]), old), file=sys.stderr); sys.exit(2)
t[keys[-1]] = json.loads(new)
pathlib.Path(out).write_text(json.dumps(d, indent=2))
'
  # Checkers: the F1 (schema), F2 (entries) and F4 (truncated.nodes) assertions of the fast lane,
  # run on the same fixture artifact, each printing one typed line. Exit 0 = RESULT=ok,
  # exit 1 = RESULT=assert-fail:<msg>; a crash prints a Traceback and no RESULT line.
  _CHK_F1='
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert d.get("schema") == "jvm-callgraph.v1", "schema"
except AssertionError as e:
    print("RESULT=assert-fail:" + str(e)); sys.exit(1)
print("RESULT=ok")
'
  _CHK_F2='
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert d.get("entries") == ["<fixture.App: void main(java.lang.String[])>"], "entries"
except AssertionError as e:
    print("RESULT=assert-fail:" + str(e)); sys.exit(1)
print("RESULT=ok")
'
  _CHK_F4='
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert d.get("truncated", {}).get("nodes") is True, "truncated.nodes"
except AssertionError as e:
    print("RESULT=assert-fail:" + str(e)); sys.exit(1)
print("RESULT=ok")
'

  # _tooth LABEL FIXTURE KEYPATH OLD NEW CHECKER MSG — build a fresh mutant dir, then run the
  # checker on the fixture (must exit 0, RESULT=ok) and on the mutant (must exit 1 with the typed
  # assert-fail line naming MSG). A refused build is counted once and its tooth never runs.
  _tooth(){
    local label="$1" fix="$2" path="$3" old="$4" new="$5" chk="$6" msg="$7" dir
    if [[ ! -f "$fix" ]]; then no "$label: fixture missing (run regen first)"; return; fi
    dir="$_MUT/$label"; mkdir -p "$dir"
    if ! python3 -c "$_BUILD" "$fix" "$dir/mutant.json" "$path" "$old" "$new"; then
      no "$label: mutant setup failed (fixture changed?)"
    elif mk "$label" "$fix" "$dir/mutant.json"; then
      tt "$label: $path mutation → $msg assertion RED (bites)" 0 1 "$dir/mutant.json" --orig "$fix" \
        --good-has '^RESULT=ok$' --bad-has "^RESULT=assert-fail:$msg\$" \
        --bad-lacks 'Traceback|Error' -- python3 -c "$chk" @SUT@
    fi
  }

  # F1: wrong schema.
  _tooth tooth-F1-schema "$_FIX_HAPPY" schema '"jvm-callgraph.v1"' '"jvm-callgraph.MUTANT"' "$_CHK_F1" schema
  # F2: entries emptied.
  _tooth tooth-F2-entries "$_FIX_HAPPY" entries '["<fixture.App: void main(java.lang.String[])>"]' '[]' "$_CHK_F2" entries
  # F4: truncated.nodes True→False. The core tightening tooth: any(values()) would stay GREEN
  # because edges/xrefs/paths stay True; only the specific assertion fires RED.
  _tooth tooth-F4-nodes "$_FIX_CAPPED" truncated.nodes true false "$_CHK_F4" truncated.nodes

  # Environment-probe controls (#1588): the S1 SKIP-vs-FAIL verdict comes from the environment
  # (was bootstrap ever run?). Fixture repos: EMPTY dir vs a dir holding the compiler-plugin jar.
  _PROBE_LIB="$HERE/lib/jvm-offline-probe.sh"
  # shellcheck source=lib/jvm-offline-probe.sh
  source "$_PROBE_LIB"
  _PD=org/apache/maven/plugins/maven-compiler-plugin/3.13.0
  mkdir -p "$_MUT/repo-empty" "$_MUT/repo-foreign/$_PD" "$_MUT/repo-ours/$_PD" "$_MUT/repo-noremote/$_PD"
  # Mirror id the bootstrap tags artifacts with: read from the settings file, as the probe does.
  _MID="$(sed -n 's:.*<id>\(.*\)</id>.*:\1:p;T;q' "$TOOLBELT/jvm-callgraph/maven-central-settings.xml")"
  [ -n "$_MID" ] || { echo "FATAL: no mirror id in maven-central-settings.xml" >&2; exit 2; }
  for _r in foreign ours noremote; do : > "$_MUT/repo-$_r/$_PD/maven-compiler-plugin-3.13.0.jar"; done
  printf 'maven-compiler-plugin-3.13.0.jar>other-project-repo=\n' > "$_MUT/repo-foreign/$_PD/_remote.repositories"
  printf 'maven-compiler-plugin-3.13.0.jar>%s=\n' "$_MID" > "$_MUT/repo-ours/$_PD/_remote.repositories"
  : > "$_MUT/repo-file"
  _probe_h='. "$1"; rsdd_jvm_build_verdict "$2" "$3"; echo "rc=$?"'
  _PSET="$TOOLBELT/jvm-callgraph/maven-central-settings.xml"   # explicit: a mutant copy lives elsewhere
  _probe(){ bash -c "$_probe_h" _ "$_PROBE_LIB" "$1" "$_PSET"; }
  if [[ "$(_probe "$_MUT/repo-empty")" == "skip: "*$'\n'rc=0 && "$(_probe "$_MUT/absent")" == "skip: "*$'\n'rc=0 \
        && "$(_probe "$_MUT/repo-noremote")" == "skip: "*$'\n'rc=0 ]]; then
    ok "probe: absent/empty/untagged local repo -> typed skip (bootstrap never ran)"
  else no "probe: absent/empty/untagged local repo -> typed skip"; fi
  if [[ "$(_probe "$_MUT/repo-foreign")" == "skip: "*$'\n'rc=0 ]]; then
    ok "probe: plugin cached by another project (foreign mirror id) -> typed skip"
  else no "probe: foreign-id plugin must not read as bootstrapped"; fi
  if [[ "$(_probe "$_MUT/repo-ours")" == "fail: bootstrap present"$'\n'rc=1 ]]; then
    ok "probe: bootstrap-tagged plugin + failing build -> fail verdict, not skip"
  else no "probe: bootstrap present -> fail verdict"; fi
  if [[ "$(_probe "$_MUT/repo-file")" == "fail: probe error:"*$'\n'rc=2 ]]; then
    ok "probe: repo path is not a directory -> probe error (fail), never skip"
  else no "probe: non-directory repo -> probe error"; fi
  # Mutant: drop the environment probe (the mirror-id match never succeeds, so everything reads
  # as absent). On the bootstrap-tagged repo the original says "fail: bootstrap present"; the
  # mutant says "skip: ..." and would mask a real build failure as a SKIP.
  if MUTANT_SYNTAX=bash mutant_chain tooth-probe-dropped "$_PROBE_LIB" "$_MUT/probe-mut.sh" \
       's/0) echo "fail: bootstrap present"; return 1 ;;/0) ;;/'; then
    tt "tooth-probe-dropped: probe removed -> bootstrap-present build failure masked as skip (bites)" 0 0 "$_MUT/probe-mut.sh" \
      --orig "$_PROBE_LIB" --good-has '^fail: bootstrap present$' --bad-has '^skip: ' \
      --bad-lacks '^fail: bootstrap present$' -- bash -c "$_probe_h" _ @SUT@ "$_MUT/repo-ours" "$_PSET"
  else fail=$((fail+1)); fi

  # Build-settings control (#1588, real SUT defect): `bootstrap` populates the local Maven repo
  # under the mirror id research-sdd-central-only, so an offline `build` WITHOUT the same settings
  # file cannot resolve anything ("has not been downloaded from it before"). A fake mvn records
  # whether the wrapper handed it -o and any -s (path-independent); `build` must pass both. mutant_chain
  # refuses an identity mutant (rc 4), so a no-op mutation cannot make this tooth vacuous.
  # Typed degraded state (not a FAIL) when no usable Java 21 exists: the wrapper exits 3 before mvn.
  if (. "$TOOLBELT/lib/tool-env.sh"; rsdd_resolve_java_home >/dev/null 2>&1); then
    mkdir -p "$_MUT/fakebin" "$_MUT/bs-mut"
    cat > "$_MUT/fakebin/mvn" <<'FAKE'
#!/bin/sh
# Typed, path-independent record of what the wrapper handed mvn: OFFLINE/SETTINGS = present|absent.
o=absent; st=absent
for a in "$@"; do case "$a" in -o) o=present ;; -s) st=present ;; esac; done
printf 'OFFLINE=%s SETTINGS=%s\n' "$o" "$st" > "$FAKE_MVN_ARGS"
FAKE
    chmod +x "$_MUT/fakebin/mvn"
    ln -s "$TOOLBELT/lib" "$_MUT/bs-mut/lib"; ln -s "$TOOLBELT/jvm-callgraph" "$_MUT/bs-mut/jvm-callgraph"
    _build_h='PATH="$1/fakebin:$PATH" FAKE_MVN_ARGS="$1/mvn.args" bash "$2" build >/dev/null 2>&1; echo "rc=$?"; cat "$1/mvn.args" 2>/dev/null'
    if MUTANT_SYNTAX=bash mutant_chain tooth-build-settings "$WRAPPER" "$_MUT/bs-mut/jvm-callgraph.sh" \
         's| -s "\$MODULE/maven-central-settings.xml"||'; then
      tt "tooth-build-settings: build must pass -o and -s <bootstrap settings> to mvn" 0 0 "$_MUT/bs-mut/jvm-callgraph.sh" \
        --orig "$WRAPPER" --good-has '^OFFLINE=present SETTINGS=present$' --bad-has '^OFFLINE=present SETTINGS=absent$' \
        --bad-lacks '^OFFLINE=present SETTINGS=present$' -- \
        bash -c "$_build_h" _ "$_MUT" @SUT@
    else fail=$((fail+1)); fi
  else
    printf '  SKIP  tooth-build-settings: no usable Java 21 (wrapper exits 3 before mvn)\n'
  fi

  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
