#!/usr/bin/env bash
# Focused integration contract for the non-executing SootUp call-graph CLI.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HERE/../jvm-callgraph.sh"
[ -f "$WRAPPER" ] || { echo "FATAL: SUT not found: $WRAPPER" >&2; exit 2; }

# Tool-availability guard — skip gracefully when a usable Java 21 is absent.
# `command -v java` is NOT enough: the suite compiles with `javac --release 21`,
# so a present-but-older java (as on minimal CI images) must still skip. Resolve
# Java 21 exactly as the suite does, via the shared rsdd_resolve_java_home helper.
_JAVA21="$(bash -c 'source "$1"; rsdd_resolve_java_home' _ "$HERE/../lib/tool-env.sh" 2>/dev/null)"
# rsdd_resolve_java_home returns any resolvable JDK (it does not gate on version),
# so verify the major feature version is >= 21 — an older javac cannot `--release 21`.
_JAVAC_MAJOR="$([ -x "${_JAVA21:-}/bin/javac" ] && "$_JAVA21/bin/javac" -version 2>&1 | grep -oE '[0-9]+' | head -1)"
if [ -z "$_JAVA21" ] || [ ! -x "$_JAVA21/bin/javac" ] || [ "${_JAVAC_MAJOR:-0}" -lt 21 ]; then
  echo "SKIP: jvm-callgraph tests (missing: usable Java 21)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi
# Maven guard — the build step requires mvn; skip gracefully when absent.
if ! command -v mvn >/dev/null 2>&1; then
  echo "SKIP: jvm-callgraph tests (missing: mvn)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1: ${2:-}"; fail=$((fail+1)); }
run() { "$WRAPPER" analyze "$@"; }

if "$WRAPPER" build >"$ROOT/build.log" 2>&1; then ok "offline Java 21 Maven build"
else no "offline Java 21 Maven build" "$(tail -5 "$ROOT/build.log")"; fi

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
JAVA21="$_JAVA21"
"$JAVA21/bin/javac" --release 21 -d "$ROOT/classes" "$ROOT"/src/fixture/*.java
"$JAVA21/bin/jar" --create --file "$ROOT/fixture.jar" -C "$ROOT/classes" .

COMMON=(--input "$ROOT/fixture.jar" --sink-contains "fixture.Sink: void write" --max-depth 8 --max-paths 10 --max-nodes 100 --max-edges 100 --max-xrefs 100)
if run "${COMMON[@]}" --output "$ROOT/a.json" && run "${COMMON[@]}" --output "$ROOT/b.json" && cmp -s "$ROOT/a.json" "$ROOT/b.json" && [ ! -e "$MARKER" ]; then
  ok "main discovery is deterministic and never executes fixture"
else no "main discovery is deterministic and never executes fixture"; fi

if python3 - "$ROOT/a.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["schema"] == "jvm-callgraph.v1" and d["algorithm"] == "CHA"
assert d["entries"] == ["<fixture.App: void main(java.lang.String[])>"]
assert d["reverse_xrefs"] == [{"callers":["<fixture.Transform: void normalize(int)>"],"sink":"<fixture.Sink: void write(java.lang.String)>"}]
assert d["paths"][0]["methods"] == ["<fixture.App: void main(java.lang.String[])>","<fixture.Router: void route(int)>","<fixture.Transform: void normalize(int)>","<fixture.Sink: void write(java.lang.String)>"]
assert d["tool"]["components"] == ["org.soot-oss:sootup.callgraph:2.0.0","org.soot-oss:sootup.java.bytecode.frontend:2.0.0"]
assert d["runtime"]["major"] >= 21 and d["errors"] == [] and d["completeness"] == "partial"
PY
then ok "JSON binds identities, edges, xrefs, paths, and limitations"; else no "JSON contract"; fi

ENTRY='<fixture.App: void main(java.lang.String[])>'
if run --input "$ROOT/fixture.jar" --entry "$ENTRY" --sink-contains "fixture.Sink: void write" --output "$ROOT/explicit.json"; then ok "exact entry signature"
else no "exact entry signature"; fi
if ! run --input "$ROOT/fixture.jar" --entry '<fixture.Missing: void main(java.lang.String[])>' --output "$ROOT/missing.json" 2>"$ROOT/missing.err" && grep -q 'entry method not found' "$ROOT/missing.err"; then ok "missing entry fails closed"
else no "missing entry fails closed"; fi

"$JAVA21/bin/jar" --create --file "$ROOT/no-main.jar" -C "$ROOT/classes" fixture/Sink.class
if ! run --input "$ROOT/no-main.jar" --output "$ROOT/no-main.json" 2>"$ROOT/no-main.err" \
  && grep -q 'no application main method found' "$ROOT/no-main.err"; then ok "omitted entry fails when no main exists"
else no "omitted entry fails when no main exists"; fi

if run --input "$ROOT/fixture.jar" --sink-contains fixture --max-depth 1 --max-paths 1 --max-nodes 1 --max-edges 1 --max-xrefs 1 --output "$ROOT/capped.json" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(d["truncated"].values())' "$ROOT/capped.json"; then ok "depth and output caps are explicit"
else no "depth and output caps are explicit"; fi

if ! run "${COMMON[@]}" --output "$ROOT/a.json" 2>/dev/null && run "${COMMON[@]}" --output "$ROOT/a.json" --overwrite; then ok "output collision requires overwrite"
else no "output collision requires overwrite"; fi
if ! run --input "$ROOT/fixture.jar" --output "$ROOT/fixture.jar" --overwrite 2>/dev/null; then ok "output cannot overwrite analyzed input"
else no "output cannot overwrite analyzed input"; fi

ln -s "$ROOT/fixture.jar" "$ROOT/link.jar"
if ! run --input "$ROOT/link.jar" --output "$ROOT/link.json" 2>/dev/null \
  && ! run --input "$ROOT/fixture.jar" --input "$ROOT/fixture.jar" --output "$ROOT/dup.json" 2>/dev/null \
  && ! run --input "$ROOT/fixture.jar" --max-depth 0 --output "$ROOT/bad-cap.json" 2>/dev/null; then ok "unsafe files, duplicate options, and invalid caps fail closed"
else no "unsafe files, duplicate options, and invalid caps fail closed"; fi

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
"$JAVA21/bin/javac" --release 21 -d "$ROOT/many-classes" "$ROOT"/many-src/many/*.java
"$JAVA21/bin/jar" --create --file "$ROOT/many.jar" -C "$ROOT/many-classes" many/AppMany.class
if run --input "$ROOT/many.jar" --output "$ROOT/many.json" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["counts"]; assert c["unresolved_total"] > 100 and c["unresolved_emitted"] == len(d["unresolved"]) == 100 and d["truncated"]["unresolved"]' "$ROOT/many.json"; then ok "unresolved totals remain complete above emission cap"
else no "unresolved totals remain complete above emission cap"; fi

mkdir -p "$ROOT/real/sub"; cp "$ROOT/fixture.jar" "$ROOT/real/sub/evidence.jar"; ln -s "$ROOT/real" "$ROOT/alias"
before="$(sha256sum "$ROOT/real/sub/evidence.jar")"
if ! run --input "$ROOT/real/sub/evidence.jar" --output "$ROOT/alias/sub/evidence.jar" --overwrite 2>/dev/null \
  && [ "$(sha256sum "$ROOT/real/sub/evidence.jar")" = "$before" ]; then ok "ancestor symlink cannot alias output to input"
else no "ancestor symlink cannot alias output to input"; fi

mkdir -p "$ROOT/stage-probe-src/researchsdd/callgraph" "$ROOT/stage-probe-classes"
cat > "$ROOT/stage-probe-src/researchsdd/callgraph/StageCopyProbe.java" <<'JAVA'
package researchsdd.callgraph;
import java.nio.file.Files;
import java.nio.file.Path;
public final class StageCopyProbe {
  public static void main(String[] args) throws Exception {
    Main.FileIdentity expected = new Main.FileIdentity("original.jar", Long.parseLong(args[1]), args[2]);
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
"$JAVA21/bin/javac" --release 21 -cp "$HERE/../jvm-callgraph/target/jvm-callgraph.jar" \
  -d "$ROOT/stage-probe-classes" "$ROOT/stage-probe-src/researchsdd/callgraph/StageCopyProbe.java"
if "$JAVA21/bin/java" -cp "$HERE/../jvm-callgraph/target/jvm-callgraph.jar:$ROOT/stage-probe-classes" \
  researchsdd.callgraph.StageCopyProbe "$ROOT/no-main.jar" "$(stat -c %s "$ROOT/fixture.jar")" \
  "$(sha256sum "$ROOT/fixture.jar" | cut -d' ' -f1)" "$ROOT/GRAPH_CONSTRUCTED" \
  && [ ! -e "$ROOT/GRAPH_CONSTRUCTED" ]; then ok "changed private copy is rejected before graph construction"
else no "changed private copy is rejected before graph construction"; fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
