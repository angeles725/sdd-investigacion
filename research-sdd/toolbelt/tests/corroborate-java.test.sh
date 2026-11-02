#!/usr/bin/env bash
# Shim-level contract for `rsdd corroborate java`; the engine is covered by Go tests under rsdd/internal/corroborate/java.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-java.sh"
MANIFEST="$HERE/../analysis_manifest.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in bwrap java; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: corroborate-java tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

ROOT="$(mktemp -d)"; trap 'find "$ROOT" -type d -name trusted-tools -exec chmod u+w {} + 2>/dev/null; rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1: ${2:-}"; fail=$((fail+1)); }

REAL_JAVA="$(bash -c 'source "$1"; rsdd_resolve_java_home' _ "$HERE/../lib/tool-env.sh" 2>/dev/null)"
if [ -z "$REAL_JAVA" ] || [ ! -x "$REAL_JAVA/bin/javac" ]; then
  echo "SKIP: corroborate-java tests (missing: usable Java 21)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi
mkdir -p "$ROOT/src/fixture" "$ROOT/classes" "$ROOT/fake-java/bin" "$ROOT/fake-runtime/bin" "$ROOT/tools" "$ROOT/space dir"
MARKER="$ROOT/FIXTURE_EXECUTED"
WRAPPER_MARKER="$ROOT/WRAPPER_EXECUTED"
cat > "$ROOT/src/fixture/App.java" <<JAVA
package fixture;
import java.nio.file.*;
public final class App {
  static { try { Files.writeString(Path.of("$MARKER"), "executed"); } catch (Exception e) { throw new RuntimeException(e); } }
  public static void main(String[] args) { System.out.println("fixture"); }
}
JAVA
"$REAL_JAVA/bin/javac" --release 21 -d "$ROOT/classes" "$ROOT/src/fixture/App.java"
"$REAL_JAVA/bin/jar" --create --file "$ROOT/space dir/fixture app.jar" -C "$ROOT/classes" .

python3 - "$ROOT/tools" <<'PY'
import pathlib,sys,zipfile
root=pathlib.Path(sys.argv[1])
entries={"vineflower.jar":"org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class","cfr.jar":"org/benf/cfr/reader/Main.class","procyon.jar":"com/strobel/decompiler/DecompilerDriver.class","cfr-fail.jar":"org/benf/cfr/reader/Main.class","cfr-spam.jar":"org/benf/cfr/reader/Main.class","vineflower-slow.jar":"org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class"}
for name,entry in entries.items():
    with zipfile.ZipFile(root/name,"w") as z:
        z.writestr(entry,b"stub")
        if "fail" in name: z.writestr("FAIL",b"")
        if "spam" in name: z.writestr("SPAM",b"")
        if "slow" in name: z.writestr("SLOW",b"")
PY

cat > "$ROOT/fake-runtime/bin/java" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -version ]; then echo 'openjdk version "21.0.1"' >&2; exit 0; fi
case "${1:-}" in -Xmx*) shift;; esac
[ "${1:-}" = -jar ] || exit 90; jar="$2"; shift 2
if grep -qx SLOW <<<"$(unzip -Z1 "$jar")"; then sleep 3; fi
if grep -qx FAIL <<<"$(unzip -Z1 "$jar")"; then echo 'stub failure' >&2; exit 7; fi
case "$(basename "$jar")" in
  vineflower*) [ "${1:-}" = --thread-count=1 ] || exit 94; shift; in="$1"; out="$2" ;;
  cfr*) in="$1"; [ "$2" = --outputdir ] || exit 91; out="$3" ;;
  procyon*) [ "$1" = -jar ] || exit 92; in="$2"; [ "$3" = -o ] || exit 93; out="$4" ;;
esac
mkdir -p "$out/fixture"
if grep -qx SPAM <<<"$(unzip -Z1 "$jar")"; then
  for name in $(seq 1 20); do head -c 1024 /dev/zero > "$out/fixture/$name.java"; done
  head -c 131072 /dev/zero >&2
  exit 8
fi
printf 'package fixture; public final class App { public static void main(String[] a) {} }\n' > "$out/fixture/App.java"
if [[ "$PWD" == *'.out one.stage' ]]; then names=(Z A); else names=(A Z); fi
for name in "${names[@]}"; do printf 'final class %s {}\n' "$name" > "$out/fixture/$name.java"; done
printf 'stage=%s\n' "$PWD" >&2
echo "adapter=$(basename "$jar") input=$(basename "$in")"
SH
cat > "$ROOT/fake-runtime/bin/javap" <<'SH'
#!/usr/bin/env bash
printf 'stage=%s\n' "$PWD" >&2
cat <<'EOF'
public final class fixture.App {
  public static void main(java.lang.String[]);
    descriptor: ([Ljava/lang/String;)V
}
EOF
SH
cat > "$ROOT/fake-runtime/bin/jdeps" <<'SH'
#!/usr/bin/env bash
printf 'stage=%s\n' "$PWD" >&2
echo 'fixture.App -> java.lang.Object java.base'
SH
chmod +x "$ROOT/fake-runtime/bin/"{java,javap,jdeps}
ln -s ../../fake-runtime/bin/java "$ROOT/fake-java/bin/java"
ln -s ../../fake-runtime/bin/javap "$ROOT/fake-java/bin/javap"
ln -s ../../fake-runtime/bin/jdeps "$ROOT/fake-java/bin/jdeps"

cat > "$ROOT/wrapper-trap" <<SH
#!/usr/bin/env bash
touch "$WRAPPER_MARKER"
exit 99
SH
chmod +x "$ROOT/wrapper-trap"

BASE_ENV=(JAVA_HOME="$ROOT/fake-java" RSDD_BWRAP=/usr/bin/bwrap RSDD_DECOMPILE_WRAPPER="$ROOT/wrapper-trap"
  VINEFLOWER_JAR="$ROOT/tools/vineflower.jar" VINEFLOWER_SHA256="$(sha256sum "$ROOT/tools/vineflower.jar" | cut -d' ' -f1)"
  CFR_JAR="$ROOT/tools/cfr.jar" CFR_SHA256="$(sha256sum "$ROOT/tools/cfr.jar" | cut -d' ' -f1)"
  PROCYON_JAR="$ROOT/tools/procyon.jar" PROCYON_SHA256="$(sha256sum "$ROOT/tools/procyon.jar" | cut -d' ' -f1)" SECRET_TOKEN=do-not-persist)
ARGS=(--input "$ROOT/space dir/fixture app.jar" --timeout-seconds 2 --max-heap 128m --max-files 100 --max-bytes 1048576 --max-classes 100)

if env "${BASE_ENV[@]}" "$SUT" "${ARGS[@]}" --output "$ROOT/out one" && [ ! -e "$MARKER" ] && [ ! -e "$WRAPPER_MARKER" ]; then ok "five isolated adapters succeed without target or wrapper execution"
else no "five adapters succeed without target execution"; fi

if python3 - "$ROOT/out one" "$MANIFEST" "$ROOT/fake-runtime/bin" "$ROOT/tools" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); real=pathlib.Path(sys.argv[3]); sources=pathlib.Path(sys.argv[4]); outer=pathlib.Path('/usr/bin/bwrap').resolve(); d=json.loads((root/'java-corroboration.v1.json').read_text())
assert d['schema']=='java-corroboration.v1' and d['status']=='complete'
assert sorted(d['engines'])==['cfr','javap','jdeps','procyon','vineflower']
assert all(v['status']=='success' for v in d['engines'].values())
assert d['expected_classes']==['fixture.App'] and d['javap_signatures']
for name,engine in d['engines'].items():
    manifest=root/engine['manifest']; assert manifest.is_file()
    assert subprocess.run([sys.executable,sys.argv[2],'validate',manifest]).returncode==0
    assert subprocess.run([sys.executable,sys.argv[2],'verify','--root',root,manifest]).returncode==0
    document=json.loads(manifest.read_text())
    expected=(real/('java' if name in ('vineflower','cfr','procyon') else name)).resolve()
    assert pathlib.Path(document['argv'][0])==outer and pathlib.Path(document['tool']['launcher']['resolved_executable'])==outer
    assert '--unshare-net' in document['argv'] and document['argv'][document['argv'].index('--ro-bind')+1]=='/'
    assert ['--setenv','HOME','/tmp/rsdd/home']==document['argv'][document['argv'].index('--setenv'):document['argv'].index('--setenv')+3]
    assert all(document['argv'][a['argv_index']]==a['path'] for a in document['tool']['artifacts'])
    assert str(expected) in [a['path'] for a in document['tool']['artifacts']] and all('decompile-java.sh' not in arg and 'wrapper-trap' not in arg for arg in document['argv'])
    assert document['isolation_profile']=={'name':'bubblewrap-static-network-denied','network_access':False,'static_only':True,'target_execution':False}
    assert 'No operating-system network sandbox is enforced.' not in document['limitations'] and any('WSL' in item for item in document['limitations'])
    if name in ('vineflower','cfr','procyon'):
        staged=pathlib.Path('trusted-tools')/(name+'.jar'); source=sources/(name+'.jar')
        evidence=json.loads((manifest.parent/'trusted-source.json').read_text())
        assert str(source) not in document['argv'] and staged.as_posix() in document['argv']
        pos=document['argv'].index(staged.as_posix()); assert document['argv'][pos-1]=='--ro-bind' and document['argv'][pos+1]=='/tmp/rsdd/tools/'+name+'.jar'
        assert evidence['source']['sha256']==evidence['staged']['sha256'] and evidence['source']['path']==str(source.resolve())
        assert (root/staged).stat().st_mode & 0o777==0o400 and (root/'trusted-tools').stat().st_mode & 0o777==0o500
        assert f'engines/{name}/output' in document['argv'] and document['argv'][document['argv'].index(f'engines/{name}/output')-1]=='--bind'
    assert document['tool']['launcher']['sha256'].startswith('sha256:')
    assert not (manifest.parent/'stdout.raw.txt').exists() and not (manifest.parent/'stderr.raw.txt').exists()
    assert '<STAGING_ROOT>' in (manifest.parent/'stderr.txt').read_text()
PY
then ok "canonical launchers and bounded canonical diagnostics validate"; else no "canonical launchers and diagnostics"; fi

if env "${BASE_ENV[@]}" "$SUT" "${ARGS[@]}" --output "$ROOT/out two" \
  && cmp -s "$ROOT/out one/java-corroboration.v1.json" "$ROOT/out two/java-corroboration.v1.json" \
  && ! grep -Rqs 'do-not-persist' "$ROOT/out one"; then ok "stable report is deterministic and secret-free"
else no "stable report is deterministic and secret-free"; fi

if ! env "${BASE_ENV[@]}" CFR_JAR="$ROOT/tools/cfr-fail.jar" CFR_SHA256="$(sha256sum "$ROOT/tools/cfr-fail.jar" | cut -d' ' -f1)" "$SUT" "${ARGS[@]}" --output "$ROOT/partial" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="partial" and d["engines"]["cfr"]["status"]=="failed" and d["engines"]["vineflower"]["status"]=="success"' "$ROOT/partial/java-corroboration.v1.json"; then ok "one adapter failure preserves partial evidence"
else no "one adapter failure preserves partial evidence"; fi

# warn-java: rc=1 path emits warn_evidence stderr pointer (§7 anti-silent-zero).
# Uses cfr-fail.jar (already staged above) to force failures=["cfr"] → rc=1.
# Captures the process stderr and asserts the schema + .json path appear.
# NOTE: VINEFLOWER_SHA256 must be recomputed here — the source-mutation test
# (above) appends content to vineflower.jar, invalidating the hash in BASE_ENV.
_vf_warn_sha="$(sha256sum "$ROOT/tools/vineflower.jar" | cut -d' ' -f1)"
if ! env "${BASE_ENV[@]}" \
    VINEFLOWER_SHA256="$_vf_warn_sha" \
    CFR_JAR="$ROOT/tools/cfr-fail.jar" \
    CFR_SHA256="$(sha256sum "$ROOT/tools/cfr-fail.jar" | cut -d' ' -f1)" \
    "$SUT" "${ARGS[@]}" --output "$ROOT/warn-java-ptr" 2>"$ROOT/java-warn.err" \
  && grep -q 'java-corroboration.v1' "$ROOT/java-warn.err" \
  && grep -q 'java-corroboration.v1.json' "$ROOT/java-warn.err"; then
  ok "warn-java: rc=1 main() emits warn_evidence pointer for java-corroboration.v1 in stderr"
else no "warn-java: rc=1 warn_evidence pointer missing from stderr"; fi

# Shim wiring: the wrapper hands the whole job to `rsdd corroborate java` and no longer runs the retired script.
SHIM_TEXT="$(cat "$SUT")"
if grep -q 'rsdd_exec corroborate java' <<<"$SHIM_TEXT" && ! grep -q 'corroborate_java.py' <<<"$SHIM_TEXT" \
  && [ ! -e "$HERE/../corroborate_java.py" ]; then ok "shim delegates to rsdd corroborate java; corroborate_java.py is retired"
else no "shim delegates to rsdd corroborate java; corroborate_java.py is retired"; fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
