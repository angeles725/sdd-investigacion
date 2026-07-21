#!/usr/bin/env bash
# Focused contract for bounded, non-executing Java multi-engine corroboration.
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

REAL_JAVA="$(RESEARCH_SDD_JAVA_HOME="${RESEARCH_SDD_JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@21}" bash -c 'source "$1"; rsdd_resolve_java_home' _ "$HERE/../lib/tool-env.sh")"
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
if unzip -Z1 "$jar" | grep -qx SLOW; then sleep 3; fi
if unzip -Z1 "$jar" | grep -qx FAIL; then echo 'stub failure' >&2; exit 7; fi
case "$(basename "$jar")" in
  vineflower*) [ "${1:-}" = --thread-count=1 ] || exit 94; shift; in="$1"; out="$2" ;;
  cfr*) in="$1"; [ "$2" = --outputdir ] || exit 91; out="$3" ;;
  procyon*) [ "$1" = -jar ] || exit 92; in="$2"; [ "$3" = -o ] || exit 93; out="$4" ;;
esac
mkdir -p "$out/fixture"
if unzip -Z1 "$jar" | grep -qx SPAM; then
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

if ! env "${BASE_ENV[@]}" VINEFLOWER_JAR="$ROOT/tools/vineflower-slow.jar" VINEFLOWER_SHA256="$(sha256sum "$ROOT/tools/vineflower-slow.jar" | cut -d' ' -f1)" "$SUT" "${ARGS[@]}" --timeout-seconds 1 --output "$ROOT/timeout" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["engines"]["vineflower"]["status"]=="timeout"' "$ROOT/timeout/java-corroboration.v1.json"; then ok "per-adapter timeout is explicit"
else no "per-adapter timeout is explicit"; fi

if ! env "${BASE_ENV[@]}" CFR_JAR="$ROOT/tools/cfr-spam.jar" CFR_SHA256="$(sha256sum "$ROOT/tools/cfr-spam.jar" | cut -d' ' -f1)" \
  "$SUT" --input "$ROOT/space dir/fixture app.jar" --output "$ROOT/capped" --timeout-seconds 2 \
  --max-heap 128m --max-files 100 --max-bytes 4096 --max-classes 100 \
  && python3 - "$ROOT/capped" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); report=json.loads((root/'java-corroboration.v1.json').read_text()); cfr=report['engines']['cfr']
assert report['status']=='partial' and report['truncated']['adapter_caps']
assert cfr['status']=='cap_exceeded' and any(cfr['truncated'].values())
assert report['engines']['vineflower']['status']=='success'
engine=root/'engines/cfr'; diagnostics=sum((engine/name).stat().st_size for name in ('stdout.txt','stderr.txt'))
assert cfr['output_inventory'] and sum(item['size'] for item in cfr['output_inventory']) > 0
assert diagnostics+sum(item['size'] for item in cfr['output_inventory']) <= 4096
assert len(cfr['output_inventory']) <= 100
assert not list(engine.glob('*.raw.txt'))
actual=sorted(path.relative_to(engine/'output').as_posix() for path in (engine/'output').rglob('*') if path.is_file())
assert actual==sorted(item['path'] for item in cfr['output_inventory'])
PY
then ok "caps preserve strictly bounded per-engine partial evidence"; else no "bounded per-engine cap evidence"; fi

if python3 - "$HERE/../corroborate_java.py" "$ROOT/runtime-cap" <<'PY'
import errno,importlib.util,os,pathlib,sys
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
root=pathlib.Path(sys.argv[2]); engine=root/'engine'; output=engine/'output'; output.mkdir(parents=True)
program='''import errno,pathlib,signal,sys
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
path=pathlib.Path(sys.argv[1])
try:
    path.write_bytes(b"x" * 1048576)
except OSError as exc:
    print(exc.errno)
    raise SystemExit(23 if exc.errno == errno.EFBIG else 24)
raise SystemExit(25)
'''
command=module.isolation_prefix(pathlib.Path('/usr/bin/bwrap'),'engine/output')
command += [sys.executable,'-c',program,module.SANDBOX_ROOT+'/engine/output/million.bin']
outcome=module.run_adapter(command,root,engine,os.environ.copy(),2,10,4096)
artifact=output/'million.bin'
assert outcome['returncode']==23 and artifact.stat().st_size==4096
assert (engine/'stdout.raw.txt').read_text().strip()==str(errno.EFBIG)
PY
then ok "RLIMIT_FSIZE prevents a 1 MiB generated file from exceeding 4 KiB during execution"; else no "execution-time generated-file cap"; fi

if python3 - "$HERE/../corroborate_java.py" "$ROOT/inherited-pipes" <<'PY'
import importlib.util,os,pathlib,signal,sys,time
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
root=pathlib.Path(sys.argv[2]); engine=root/'engine'; engine.mkdir(parents=True)
program='''import os,pathlib,signal,time
pid=os.fork()
if pid: pathlib.Path("child.pid").write_text(str(pid)); raise SystemExit(0)
signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)
'''
started=time.monotonic(); outcome=module.run_adapter([sys.executable,'-c',program],root,engine,os.environ.copy(),1,10,4096)
child=int((root/'child.pid').read_text()); elapsed=time.monotonic()-started
for _ in range(100):
    try: state=pathlib.Path(f'/proc/{child}/stat').read_text().split()[2]
    except FileNotFoundError: state='Z'
    if state=='Z': break
    time.sleep(.01)
assert elapsed < 1.5 and state=='Z' and outcome['status']=='success'
PY
then ok "adapter descendants retaining pipes are killed within the wall deadline"; else no "inherited-pipe deadline"; fi

if python3 - "$HERE/../corroborate_java.py" "$MANIFEST" "$ROOT/inventory-cap" <<'PY'
import hashlib,importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
manifest_spec=importlib.util.spec_from_file_location('analysis_manifest',sys.argv[2]); manifest=importlib.util.module_from_spec(manifest_spec); manifest_spec.loader.exec_module(manifest)
stage=pathlib.Path(sys.argv[3]); output=stage/'output'; output.mkdir(parents=True)
artifact=output/'sole.bin'; artifact.write_bytes(b'a' * 4096 + b'b')
records,truncated=module.output_inventory(manifest,stage,output,10,4096)
assert truncated and records==[{'path':'sole.bin','size':4096,'sha256':'sha256:'+hashlib.sha256(b'a' * 4096).hexdigest()}]
assert artifact.read_bytes()==b'a' * 4096
PY
then ok "sole oversized artifact retains a truthful deterministic bounded prefix"; else no "retained partial generated evidence"; fi

if ! env "${BASE_ENV[@]}" "$SUT" "${ARGS[@]}" --output "$ROOT/out one" 2>/dev/null \
  && env "${BASE_ENV[@]}" "$SUT" "${ARGS[@]}" --output "$ROOT/out one" --overwrite; then ok "existing root requires explicit overwrite"
else no "existing root requires explicit overwrite"; fi

if python3 - "$HERE/../corroborate_java.py" "$ROOT/publication" <<'PY'
import importlib.util,os,pathlib,sys
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
destination=pathlib.Path(sys.argv[2]); destination.mkdir(); (destination/'.corroborate-java-stage').write_bytes(module.STAGE_MARKER); (destination/'old').write_text('old')
lock=module.lock_publication_parent(destination)
try:
    stage=module.prepare_stage(destination); (stage/'new').write_text('new')
    cleanup=module.remove_private_tree
    module.remove_private_tree=lambda path: (_ for _ in ()).throw(KeyboardInterrupt())
    try: module.publish(stage,destination,True)
    except KeyboardInterrupt: pass
    else: raise AssertionError('simulated interruption did not occur')
    assert (destination/'new').read_text()=='new' and not (destination/'old').exists()
    assert (stage/'old').read_text()=='old' and not list(destination.parent.glob('.publication.backup-*'))
    module.remove_private_tree=cleanup
    recovered=module.prepare_stage(destination)
    assert (destination/'new').read_text()=='new' and not (recovered/'old').exists()
    module.remove_private_tree(recovered)
finally:
    os.close(lock)
PY
then ok "interrupted overwrite remains visible and next run recovers deterministically"; else no "overwrite interruption recovery"; fi

ln -s "$ROOT/space dir" "$ROOT/input-alias"
ln -s "$ROOT/tools/vineflower.jar" "$ROOT/tools/vineflower-link.jar"
before="$(sha256sum "$ROOT/space dir/fixture app.jar")"
if ! env "${BASE_ENV[@]}" "$SUT" "${ARGS[@]}" --output "$ROOT/input-alias" --overwrite 2>/dev/null \
  && [ "$(sha256sum "$ROOT/space dir/fixture app.jar")" = "$before" ] \
  && ! env "${BASE_ENV[@]}" VINEFLOWER_JAR="$ROOT/tools/vineflower-link.jar" "$SUT" "${ARGS[@]}" --output "$ROOT/artifact-link" 2>/dev/null; then ok "collisions and symlinks fail closed"
else no "collisions and symlinks fail closed"; fi

if ! env "${BASE_ENV[@]}" VINEFLOWER_SHA256= "$SUT" "${ARGS[@]}" --output "$ROOT/no-pin" 2>/dev/null \
  && ! env "${BASE_ENV[@]}" CFR_SHA256="$(printf '0%.0s' {1..64})" "$SUT" "${ARGS[@]}" --output "$ROOT/bad-pin" 2>/dev/null \
  && ! env "${BASE_ENV[@]}" RSDD_BWRAP="$ROOT/missing-bwrap" "$SUT" "${ARGS[@]}" --output "$ROOT/no-isolation" 2>/dev/null \
  && [ ! -e "$ROOT/no-pin" ] && [ ! -e "$ROOT/.no-pin.stage" ] && [ ! -e "$ROOT/bad-pin" ] && [ ! -e "$ROOT/.bad-pin.stage" ] \
  && [ ! -e "$ROOT/no-isolation" ] && [ ! -e "$ROOT/.no-isolation.stage" ]; then ok "missing trust or isolation refuses and cleans up before analyzer execution"
else no "missing trust or isolation refuses before analyzer execution"; fi

if ! env "${BASE_ENV[@]}" RSDD_BWRAP=/usr/bin/true "$SUT" "${ARGS[@]}" \
  --output "$ROOT/wrong-isolator" 2>/dev/null \
  && [ ! -e "$ROOT/wrong-isolator" ] && [ ! -e "$ROOT/.wrong-isolator.stage" ] \
  && [ ! -e "$MARKER" ] && [ ! -e "$WRAPPER_MARKER" ]; then ok "non-Bubblewrap launcher fails closed before analysis"
else no "non-Bubblewrap launcher fails closed before analysis"; fi

python3 - "$ROOT/unsafe.jar" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],"w") as z: z.writestr("../escape.class",b"class")
PY
if ! env "${BASE_ENV[@]}" "$SUT" --input "$ROOT/unsafe.jar" --output "$ROOT/unsafe-out" \
  --timeout-seconds 1 --max-heap 128m --max-files 100 --max-bytes 1048576 --max-classes 100 2>/dev/null; then ok "unsafe archive entries fail before adapters"
else no "unsafe archive entries fail before adapters"; fi

staged_before="$(sha256sum "$ROOT/out one/trusted-tools/vineflower.jar" | cut -d' ' -f1)"
printf 'source changed after private copy\n' >> "$ROOT/tools/vineflower.jar"
if [ "$(sha256sum "$ROOT/out one/trusted-tools/vineflower.jar" | cut -d' ' -f1)" = "$staged_before" ] \
  && python3 "$MANIFEST" verify --root "$ROOT/out one" "$ROOT/out one/engines/vineflower/analysis-manifest.v1.json"; then ok "source mutation cannot change staged invocation evidence"
else no "source mutation cannot change staged invocation evidence"; fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
