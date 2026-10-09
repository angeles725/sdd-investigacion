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

# ── Class-file facts (kit #1205) ─────────────────────────────────────────────
# Real tiny classes built at test time: major 52 WITH a LocalVariableTable (--release 8 -g, includes a long
# constant so the constant pool has an 8-byte double-slot entry) and major 65 WITHOUT one (-g:none), plus
# three deliberately broken entries: 7 bytes (header unreadable), wrong magic, and a header-only truncation.
FX="$ROOT/facts"; mkdir -p "$FX/s8/f8" "$FX/s21/f21" "$FX/c8" "$FX/c21"
cat > "$FX/s8/f8/Old.java" <<'JAVA'
package f8;
public class Old { long big() { return 123456789012L; } String s(int a) { int x = a + 1; return "v" + x; }
  int t() { try { return 1; } catch (RuntimeException e) { return 2; } } }
JAVA
cat > "$FX/s21/f21/New.java" <<'JAVA'
package f21;
public class New { String s(int a) { int x = a + 1; return "v" + x; } }
JAVA
_fx_built=0
if "$REAL_JAVA/bin/javac" --release 8 -g -nowarn -d "$FX/c8" "$FX/s8/f8/Old.java" 2>/dev/null \
  && "$REAL_JAVA/bin/javac" --release 21 -g:none -d "$FX/c21" "$FX/s21/f21/New.java" \
  && python3 - "$FX" <<'PY'
import pathlib,sys,zipfile
fx=pathlib.Path(sys.argv[1]); old=(fx/"c8/f8/Old.class").read_bytes(); new=(fx/"c21/f21/New.class").read_bytes()
with zipfile.ZipFile(fx/"facts.jar","w") as z:
    z.writestr("f8/Old.class",old); z.writestr("f21/New.class",new)
    z.writestr("bad/Trunc.class",old[:7]); z.writestr("bad/Magic.class",b"not a class file at all"); z.writestr("bad/Body.class",new[:40])
with zipfile.ZipFile(fx/"badonly.jar","w") as z: z.writestr("bad/Trunc.class",old[:7])
# valid central directory, damaged deflate stream: flip the first compressed bytes to an invalid block type
with zipfile.ZipFile(fx/"corrupt.jar","w",zipfile.ZIP_DEFLATED) as z: z.writestr("f8/Old.class",old+b"A"*5000)
raw=bytearray((fx/"corrupt.jar").read_bytes()); name_len=int.from_bytes(raw[26:28],"little"); extra_len=int.from_bytes(raw[28:30],"little")
start=30+name_len+extra_len; raw[start:start+4]=b"\xff\xff\xff\xff"; (fx/"corrupt.jar").write_bytes(bytes(raw))
PY
then _fx_built=1; else no "class-file facts: fixture classes could not be built"; fi
_fx_env=(JAVA_HOME="$ROOT/fake-java" RSDD_BWRAP=/usr/bin/bwrap RSDD_DECOMPILE_WRAPPER="$ROOT/wrapper-trap"
  VINEFLOWER_JAR="$ROOT/tools/vineflower.jar" VINEFLOWER_SHA256="$(sha256sum "$ROOT/tools/vineflower.jar" | cut -d' ' -f1)"
  CFR_JAR="$ROOT/tools/cfr.jar" CFR_SHA256="$(sha256sum "$ROOT/tools/cfr.jar" | cut -d' ' -f1)"
  PROCYON_JAR="$ROOT/tools/procyon.jar" PROCYON_SHA256="$(sha256sum "$ROOT/tools/procyon.jar" | cut -d' ' -f1)")
if [ "$_fx_built" -eq 1 ]; then
  if env "${_fx_env[@]}" "$SUT" --input "$FX/facts.jar" --output "$FX/out" --timeout-seconds 2 --max-heap 128m \
       --max-files 100 --max-bytes 1048576 --max-classes 100 \
     && python3 - "$FX/out/java-corroboration.v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); f={r["entry"]:r for r in d["class_facts"]}
assert list(f)==sorted(f) and len(f)==5, list(f)
o=f["f8/Old.class"]; assert (o["major_version"],o["has_LocalVariableTable"],o["resugar_risk"],o["reason"])==(52,True,False,None), o
n=f["f21/New.class"]; assert (n["major_version"],n["has_LocalVariableTable"],n["resugar_risk"],n["reason"])==(65,False,True,None), n
t=f["bad/Trunc.class"]; assert (t["major_version"],t["has_LocalVariableTable"],t["resugar_risk"],t["reason"])==(None,None,None,"truncated-header"), t
m=f["bad/Magic.class"]; assert (m["major_version"],m["has_LocalVariableTable"],m["resugar_risk"],m["reason"])==(None,None,None,"bad-magic"), m
b=f["bad/Body.class"]; assert (b["major_version"],b["has_LocalVariableTable"],b["resugar_risk"],b["reason"])==(65,None,True,"truncated-body"), b
s=d["class_facts_summary"]; assert s=={"classes":5,"major_versions":[52,65],"lvt":"mixed","resugar_risk_classes":2,"unreadable_classes":2,"partial_classes":1}, s
assert any("resugar_risk" in x and "53" in x for x in d["limitations"])
PY
  then ok "class facts: per-class major, LocalVariableTable, resugar_risk and typed null+reason for broken classes"
  else no "class facts: per-class major/LVT/resugar_risk/null reasons"; fi

  if python3 - "$ROOT/out one/java-corroboration.v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); f=d["class_facts"]
assert [r["entry"] for r in f]==["fixture/App.class"] and f[0]["major_version"]==65 and f[0]["has_LocalVariableTable"] is False, f
assert d["class_facts_summary"]["lvt"]=="no" and d["class_facts_summary"]["unreadable_classes"]==0
PY
  then ok "class facts: default javac output (no -g) reports lvt=no, major 65"; else no "class facts: default javac fixture"; fi

  _cli="$(python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/facts.jar" 2>&1)"; _cli_rc=$?
  _cli1="$(python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/c8/f8/Old.class" 2>&1)"
  if [ "$_cli_rc" -eq 0 ] \
     && [ "$_cli" = "CLASSFILE major=52-65 lvt=mixed classes=5 resugar_risk=yes unreadable=2 partial=1 truncated=none" ] \
     && [ "$_cli1" = "CLASSFILE major=52 lvt=yes classes=1 resugar_risk=no unreadable=0 partial=0 truncated=none" ] \
     && [ "$(python3 "$HERE/../corroborate_java.py" classfile-facts "$ROOT/missing.jar" 2>&1)" = "CLASSFILE major=unknown lvt=unknown classes=unknown resugar_risk=unknown unreadable=unknown partial=unknown truncated=unknown reason=unreadable-input(FileNotFoundError)" ] \
     && [ "$(python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/badonly.jar" 2>&1)" = "CLASSFILE major=unknown lvt=unknown classes=1 resugar_risk=unknown unreadable=1 partial=0 truncated=none" ] \
     && ! python3 "$HERE/../corroborate_java.py" classfile-facts >/dev/null 2>&1; then
    ok "classfile-facts subcommand: aggregated CLASSFILE line for jar and .class, typed unknown for unreadable input"
  else no "classfile-facts subcommand" "got=[$_cli] [$_cli1]"; fi

  # kit #1205 RDD round 1: damaged deflate stream and bounded standalone input.
  if python3 - "$HERE/../corroborate_java.py" "$FX/corrupt.jar" <<'PY'
import importlib.util,sys,zipfile
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with zipfile.ZipFile(sys.argv[2]) as z:
    r=m.read_class_facts(z,"f8/Old.class")
assert r=={"major_version":None,"has_LocalVariableTable":None,"resugar_risk":None,"reason":"corrupt-entry"}, r
PY
  then ok "corrupt deflate entry: read_class_facts returns null + reason corrupt-entry (no crash)"
  else no "corrupt deflate entry handled by read_class_facts"; fi
  _cc="$(python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/corrupt.jar" 2>&1)"; _cc_rc=$?
  if [ "$_cc_rc" -eq 0 ] && [ "$_cc" = "CLASSFILE major=unknown lvt=unknown classes=1 resugar_risk=unknown unreadable=1 partial=0 truncated=none" ]; then
    ok "classfile-facts on a corrupt-deflate JAR: typed unreadable=1, rc 0, no traceback"
  else no "classfile-facts corrupt deflate" "rc=$_cc_rc out=[$_cc]"; fi
  _cm="$(env "${_fx_env[@]}" "$SUT" --input "$FX/corrupt.jar" --output "$FX/out-corrupt" --timeout-seconds 2 --max-heap 128m --max-files 100 --max-bytes 1048576 --max-classes 100 2>&1)"; _cm_rc=$?
  if [ "$_cm_rc" -eq 2 ] && grep -q 'corrupt JAR entry' <<<"$_cm" && ! grep -q Traceback <<<"$_cm" && [ ! -e "$FX/out-corrupt" ]; then
    ok "full run on a corrupt-deflate JAR: typed rc 2 'corrupt JAR entry', no traceback, nothing published"
  else no "full run on a corrupt-deflate JAR" "rc=$_cm_rc out=[$_cm]"; fi
  _c1="$(RSDD_CLASSFACTS_MAX_ENTRIES=1 python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/facts.jar" 2>&1)"
  _c2="$(RSDD_CLASSFACTS_MAX_BYTES=100 python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/facts.jar" 2>&1)"
  if [ "$_c1" = "CLASSFILE major=65 lvt=unknown classes=1 resugar_risk=yes unreadable=0 partial=1 truncated=entry-cap reason=facts-truncated:entry-cap" ] \
     && [ "$_c2" = "CLASSFILE major=65 lvt=unknown classes=3 resugar_risk=yes unreadable=2 partial=1 truncated=byte-cap reason=facts-truncated:byte-cap" ]; then
    ok "classfile-facts caps: entry-cap and byte-cap overflow is typed (truncated= and reason=facts-truncated:...), never a silent partial count"
  else no "classfile-facts caps" "entry=[$_c1] byte=[$_c2]"; fi
  _c3="$(RSDD_CLASSFACTS_MAX_CLASS_BYTES=10 python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/c8/f8/Old.class" 2>&1)"
  if [ "$_c3" = "CLASSFILE major=unknown lvt=unknown classes=1 resugar_risk=unknown unreadable=1 partial=0 truncated=none" ]; then
    ok "classfile-facts on an oversized direct .class: typed unreadable, file is not read"
  else no "classfile-facts oversized .class" "got=[$_c3]"; fi
  # kit #1205 RDD round 2: a malformed RSDD_CLASSFACTS_* value is a typed warning + default, never a traceback.
  _c4="$(RSDD_CLASSFACTS_MAX_ENTRIES=abc RSDD_CLASSFACTS_MAX_BYTES=0 python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/facts.jar" 2>"$FX/cfg.err")"; _c4_rc=$?
  if [ "$_c4_rc" -eq 0 ] && [ "$_c4" = "CLASSFILE major=52-65 lvt=mixed classes=5 resugar_risk=yes unreadable=2 partial=1 truncated=none" ] \
     && grep -q '^WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_ENTRIES=' "$FX/cfg.err" && grep -q '^WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_BYTES=' "$FX/cfg.err" \
     && ! grep -q Traceback "$FX/cfg.err"; then
    ok "invalid RSDD_CLASSFACTS_* values: stderr warning naming the variable, default limit used, rc 0, no traceback"
  else no "invalid RSDD_CLASSFACTS_* values" "rc=$_c4_rc out=[$_c4] err=[$(cat "$FX/cfg.err")]"; fi
  # Unicode digits pass str.isdigit() but crash int(): they must warn + default too (superscript two, Arabic-Indic three).
  _c5="$(RSDD_CLASSFACTS_MAX_ENTRIES=$'\xc2\xb2' RSDD_CLASSFACTS_MAX_BYTES=$'\xd9\xa3' python3 "$HERE/../corroborate_java.py" classfile-facts "$FX/facts.jar" 2>"$FX/uni.err")"; _c5_rc=$?
  if [ "$_c5_rc" -eq 0 ] && [ "$_c5" = "CLASSFILE major=52-65 lvt=mixed classes=5 resugar_risk=yes unreadable=2 partial=1 truncated=none" ] \
     && [ "$(grep -c '^WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_' "$FX/uni.err")" -eq 2 ] && ! grep -q Traceback "$FX/uni.err"; then
    ok "Unicode digit limits (U+00B2, U+0663): warning + default, rc 0, no traceback"
  else no "Unicode digit RSDD_CLASSFACTS_* limits" "rc=$_c5_rc out=[$_c5] err=[$(cat "$FX/uni.err")]"; fi
  if env "${_fx_env[@]}" RSDD_CLASSFACTS_MAX_ENTRIES=abc RSDD_CLASSFACTS_MAX_CLASS_BYTES=-5 "$SUT" --input "$FX/facts.jar" --output "$FX/out-badenv" --timeout-seconds 2 --max-heap 128m \
       --max-files 100 --max-bytes 1048576 --max-classes 100 2>"$FX/badenv.err" \
     && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["class_facts"])==5' "$FX/out-badenv/java-corroboration.v1.json" \
     && ! grep -q Traceback "$FX/badenv.err"; then
    ok "full corroboration run survives malformed RSDD_CLASSFACTS_* values"
  else no "full run with malformed RSDD_CLASSFACTS_*" "err=[$(cat "$FX/badenv.err")]"; fi

  if python3 - "$HERE/../corroborate_java.py" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('corroborate_java',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.RESUGAR_MIN_MAJOR==53
hdr=lambda major: b"\xca\xfe\xba\xbe\x00\x00"+major.to_bytes(2,"big")
# list edges: empty, one byte short of a header, exact 8-byte header (body missing), wrong magic with a plausible major
assert m.class_file_facts(b"")["reason"]=="truncated-header" and m.class_file_facts(b"")["major_version"] is None
assert m.class_file_facts(hdr(52)[:7])["major_version"] is None
h=m.class_file_facts(hdr(52)); assert (h["major_version"],h["resugar_risk"],h["has_LocalVariableTable"],h["reason"])==(52,False,None,"truncated-body"), h
assert m.class_file_facts(hdr(53))["resugar_risk"] is True and m.class_file_facts(hdr(52))["resugar_risk"] is False
assert m.class_file_facts(b"\xde\xad\xbe\xef\x00\x00\x00\x34")["reason"]=="bad-magic"
bad=hdr(52)+b"\x00\x02\x63"  # one constant-pool entry with an invalid tag
assert m.class_file_facts(bad)["reason"]=="bad-constant-pool-tag"
PY
  then ok "class_file_facts edges: empty, 7 bytes, header-only, threshold 52/53, bad magic, bad pool tag"
  else no "class_file_facts edge cases"; fi
fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-warn-java: removing the inline if-guard makes the behavioral test go red.
  # The mutant is corroborate_java.py without the `if failures: warn_evidence(...)` block. Both the
  # original and the mutant are run directly (Python, not the bash wrapper) with cfr-fail.jar so
  # rc=1 fires; the original must exit EXACTLY 1 and emit the java-corroboration.v1.json pointer
  # on stderr (the same two facts the warn-java case above asserts), the mutant must exit 1 and
  # emit no pointer.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  _PY_CRASH="$(mutant_crash_re py)" || exit 2
  # python mutants: no bash -n (scoped per call below, never exported: #1814)
  # Scratch lives under $ROOT, so the suite's own EXIT trap (which also restores write permission
  # on trusted-tools) cleans it on every path.
  td_java="$(mktemp -d -p "$ROOT")"
  # corroborate_java.py imports lib/ and analysis_manifest.py from its own directory, so the
  # mutant keeps a copy of both next to it.
  _java_staged=0
  if mkdir -p "$td_java/mut" && cp -R "$HERE/../lib" "$td_java/mut/lib" \
     && cp "$MANIFEST" "$td_java/mut/analysis_manifest.py"; then _java_staged=1
  else no "teeth-warn-java: could not stage the mutant dir (lib/ + analysis_manifest.py copy failed)"; fi
  # run_java_py PY — run PY with the failing-CFR environment and its own FRESH --output dir. After
  # the run it prints `EVIDENCE: status=<..>` read from the java-corroboration.v1.json artifact it
  # wrote, so a run that reached the end of main() is positively identifiable (an ImportError
  # crash writes none), and exits with the adapter's own exit code.
  run_java_py() {
    local py="$1" out rc
    out="$(mktemp -d -p "$td_java")"
    env \
      JAVA_HOME="$ROOT/fake-java" \
      RSDD_BWRAP=/usr/bin/bwrap \
      RSDD_CORROBORATE_CFR="$ROOT/tools/cfr-fail.jar" \
      CFR_SHA256="$(sha256sum "$ROOT/tools/cfr-fail.jar" | cut -d' ' -f1)" \
      RSDD_CORROBORATE_VINEFLOWER="$ROOT/tools/vineflower.jar" \
      VINEFLOWER_SHA256="$(sha256sum "$ROOT/tools/vineflower.jar" | cut -d' ' -f1)" \
      RSDD_CORROBORATE_PROCYON="$ROOT/tools/procyon.jar" \
      PROCYON_SHA256="$(sha256sum "$ROOT/tools/procyon.jar" | cut -d' ' -f1)" \
      python3 "$py" \
        --decompile-wrapper "$ROOT/wrapper-trap" \
        --manifest-module "$(dirname "$py")/analysis_manifest.py" \
        "${ARGS[@]}" --output "$out/warn-java-ptr"
    rc=$?
    python3 - "$out/warn-java-ptr/java-corroboration.v1.json" <<'PY'
import json, sys
try:
    print("EVIDENCE: status=" + str(json.load(open(sys.argv[1])).get("status")))
except (OSError, ValueError) as e:
    print("EVIDENCE: <no artifact>", e)
PY
    return "$rc"
  }
  if [ "$_java_staged" -ne 1 ]; then :   # staging failure already counted; the tooth must not run
  elif MUTANT_SYNTAX=none mutant_chain_or_count fail "teeth-warn-java" "$HERE/../corroborate_java.py" "$td_java/mut/corroborate_java.py" \
      '/^        if failures:$/{N;/\n            warn_evidence(schema=SCHEMA, destination=destination, detail=", ".join(failures))$/d;}'; then
    if mutant_tooth "teeth-warn-java: guard removed → stderr empty → warn-java assertion fires (has teeth)" 1 1 "$td_java/mut/corroborate_java.py" \
        --orig "$HERE/../corroborate_java.py" \
        --good-has 'java-corroboration\.v1\.json' --bad-has '^EVIDENCE: status=partial$' \
        --bad-lacks 'java-corroboration\.v1|Traceback|ImportError|ModuleNotFoundError' -- \
        run_java_py @SUT@; then
      pass=$((pass+1))
    else fail=$((fail+1)); fi
  fi

  # ── teeth: class-file facts (kit #1205) ────────────────────────────────────
  # Direct runner over the module (no bwrap): prints one line per class entry plus SUMMARY/EDGE lines.
  cat > "$ROOT/facts-runner.py" <<'PY'
import importlib.util,sys,zipfile
spec=importlib.util.spec_from_file_location('cj',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
recs=[]
with zipfile.ZipFile(sys.argv[2]) as z:
    for n in sorted(z.namelist()):
        r=m.read_class_facts(z,n); recs.append(r)
        print(f"{n} major={r['major_version']} lvt={r['has_LocalVariableTable']} risk={r['resugar_risk']} reason={r['reason']}")
s=m.summarize_facts(recs); print(f"SUMMARY lvt={s['lvt']} majors={s['major_versions']} unreadable={s['unreadable_classes']} partial={s['partial_classes']}")
PY
  # run_facts_main PY — full main() run on the fixture jar; prints how many class_facts the report carries.
  run_facts_main() {
    local py="$1" out; out="$(mktemp -d -p "$td_java")"
    env "${_fx_env[@]}" RSDD_CORROBORATE_VINEFLOWER="$ROOT/tools/vineflower.jar" RSDD_CORROBORATE_CFR="$ROOT/tools/cfr.jar" \
      RSDD_CORROBORATE_PROCYON="$ROOT/tools/procyon.jar" python3 "$py" --decompile-wrapper "$ROOT/wrapper-trap" --manifest-module "$(dirname "$py")/analysis_manifest.py" \
      --input "$FX/facts.jar" --output "$out/r" --timeout-seconds 2 --max-heap 128m --max-files 100 --max-bytes 1048576 --max-classes 100
    local rc=$?
    python3 - "$out/r/java-corroboration.v1.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1])); print("REPORT: class_facts=%d summary=%s" % (len(d.get("class_facts",[])), "class_facts_summary" in d))
except (OSError, ValueError) as e:
    print("REPORT: <no artifact>", e)
PY
    return "$rc"
  }
  if [ "$_java_staged" -ne 1 ] || [ "$_fx_built" -ne 1 ]; then
    no "teeth-facts: staging or fixture build failed; teeth not run"
  else
    # fx_tooth NAME SED-EXPR [mutant_tooth options...] -- ARGV...: build the mutant (the sed stage must change the file),
    # then run the original (rc 0) against the mutant. Defaults: mutant rc 0 and no Traceback/ImportError in its output.
    # Overrides, as env prefixes on the call: FX_BAD_RC=<n> (mutant's expected rc) and FX_BAD_LACKS=<ERE> (forbidden
    # mutant output; a tooth whose bite IS a crash narrows it to e.g. 'ImportError|ModuleNotFoundError').
    fx_tooth() {
      local name="$1" expr="$2"; shift 2
      local mut="$td_java/mut/cf-$name.py"
      if ! MUTANT_SYNTAX=none mutant_chain_or_count fail "teeth-facts-$name" "$HERE/../corroborate_java.py" "$mut" "$expr"; then return; fi
      if mutant_tooth "teeth-facts-$name" 0 "${FX_BAD_RC:-0}" "$mut" --orig "$HERE/../corroborate_java.py" --bad-lacks "${FX_BAD_LACKS:-$_PY_CRASH}" "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi
    }
    R=(python3 "$ROOT/facts-runner.py" @SUT@ "$FX/facts.jar")
    fx_tooth threshold 's/^RESUGAR_MIN_MAJOR = 53$/RESUGAR_MIN_MAJOR = 66/' \
      --good-has '^f21/New\.class major=65 lvt=False risk=True ' --bad-has '^f21/New\.class major=65 lvt=False risk=False ' -- "${R[@]}"
    fx_tooth major-offset 's/int\.from_bytes(data\[CLASS_MAJOR_OFFSET:CLASS_MAJOR_OFFSET + 2\], "big")/int.from_bytes(data[4:6], "big")/' \
      --good-has '^f8/Old\.class major=52 ' --good-lacks 'major=0 ' --bad-has 'major=0 ' -- "${R[@]}"
    fx_tooth header-len 's/^    if len(data) < CLASS_HEADER_LEN:$/    if len(data) < 7:/' \
      --good-has '^bad/Trunc\.class major=None lvt=None risk=None reason=truncated-header$' \
      --bad-has '^bad/Trunc\.class major=0 ' -- "${R[@]}"
    fx_tooth magic 's/^    if data\[:4\] != CLASS_MAGIC:$/    if False:/' \
      --good-has '^bad/Magic\.class major=None lvt=None risk=None reason=bad-magic$' \
      --bad-has '^bad/Magic\.class major=[0-9]+ ' -- "${R[@]}"
    fx_tooth lvt-name 's/n == b"LocalVariableTable"/n == b"LocalVariableTypeTable"/' \
      --good-has '^f8/Old\.class major=52 lvt=True ' --bad-has '^f8/Old\.class major=52 lvt=False ' -- "${R[@]}"
    fx_tooth wide-slot 's/^        index += 2 if tag in CP_WIDE_TAGS else 1$/        index += 1/' \
      --good-has '^f8/Old\.class major=52 lvt=True risk=False reason=None$' \
      --bad-lacks '^f8/Old\.class major=52 lvt=True risk=False reason=None$' -- "${R[@]}"
    fx_tooth exc-table 's/code\.take(8 \* code\.u2())/code.take(0)/' \
      --good-has '^f8/Old\.class major=52 lvt=True risk=False reason=None$' \
      --bad-lacks '^f8/Old\.class major=52 lvt=True risk=False reason=None$' -- "${R[@]}"
    fx_tooth body-reason 's/^        facts\["reason"\] = str(exc)$/        facts["reason"] = None/' \
      --good-has '^bad/Body\.class major=65 lvt=None risk=True reason=truncated-body$' \
      --bad-has '^bad/Body\.class major=65 lvt=None risk=True reason=None$' -- "${R[@]}"
    fx_tooth summary-mixed 's/"mixed" if len(lvt) == 2/"mixed" if len(lvt) == 3/' \
      --good-has '^SUMMARY lvt=mixed majors=\[52, 65\] unreadable=2 partial=1$' --bad-has '^SUMMARY lvt=yes ' -- "${R[@]}"
    fx_tooth summary-unreadable 's/sum(1 for r in records if r\["major_version"\] is None)/0/' \
      --good-has '^SUMMARY .* unreadable=2 partial=1$' --bad-has '^SUMMARY .* unreadable=0 partial=1$' -- "${R[@]}"
    fx_tooth summary-partial 's/if r\["major_version"\] is not None and r\["reason"\] is not None/if r["major_version"] is None and r["reason"] is not None/' \
      --good-has '^SUMMARY .* unreadable=2 partial=1$' --bad-has '^SUMMARY .* partial=2$' -- "${R[@]}"
    fx_tooth cli-range 's/f"{majors\[0\]}-{majors\[-1\]}"/str(majors[0])/' \
      --good-has 'CLASSFILE major=52-65 ' --bad-has 'CLASSFILE major=52 ' -- python3 @SUT@ classfile-facts "$FX/facts.jar"
    fx_tooth cli-unknown-risk "s/risk = \"unknown\" if not majors else/risk = \"no\" if not majors else/" \
      --good-has 'resugar_risk=unknown ' --bad-has 'resugar_risk=no ' -- python3 @SUT@ classfile-facts "$FX/badonly.jar"
    fx_tooth corrupt-entry 's/^        return _null_facts("corrupt-entry")$/        return _null_facts("unreadable-entry")/' \
      --good-has '^f8/Old\.class major=None lvt=None risk=None reason=corrupt-entry$' --bad-has 'reason=unreadable-entry$' -- python3 "$ROOT/facts-runner.py" @SUT@ "$FX/corrupt.jar"
    # The un-caught zlib.error IS the bite here: the mutant must die with that exact traceback (rc 1), not some other crash.
    FX_BAD_RC=1 FX_BAD_LACKS='ImportError|ModuleNotFoundError' fx_tooth corrupt-catch 's/except (zlib\.error, EOFError, NotImplementedError, zipfile\.BadZipFile):/except zipfile.BadZipFile:/' \
      --good-has 'reason=corrupt-entry$' --bad-has 'zlib\.error' -- python3 "$ROOT/facts-runner.py" @SUT@ "$FX/corrupt.jar"
    fx_tooth entry-cap 's/^                    names, truncated = names\[:max_entries\], "entry-cap"$/                    names = names[:max_entries]/' \
      --good-has 'truncated=entry-cap reason=facts-truncated:entry-cap$' --bad-has 'truncated=none$' -- env RSDD_CLASSFACTS_MAX_ENTRIES=1 python3 @SUT@ classfile-facts "$FX/facts.jar"
    fx_tooth byte-cap 's/^                        truncated = "byte-cap"; break$/                        pass/' \
      --good-has 'truncated=byte-cap reason=facts-truncated:byte-cap$' --bad-has 'classes=5 .*truncated=none$' -- env RSDD_CLASSFACTS_MAX_BYTES=100 python3 @SUT@ classfile-facts "$FX/facts.jar"
    fx_tooth direct-size 's/^            if path\.stat()\.st_size > max_class:$/            if False:/' \
      --good-has 'major=unknown .*unreadable=1 partial=0 truncated=none$' --bad-has 'major=52 ' -- env RSDD_CLASSFACTS_MAX_CLASS_BYTES=10 python3 @SUT@ classfile-facts "$FX/c8/f8/Old.class"
    fx_tooth env-invalid 's/^    if value <= 0:$/    if False:/' \
      --good-has 'classes=5 .*truncated=none$' --bad-has 'classes=0 ' -- env RSDD_CLASSFACTS_MAX_ENTRIES=abc python3 @SUT@ classfile-facts "$FX/facts.jar"
    fx_tooth env-warn 's/^            _WARNED.add(name); print(.*$/            pass/' \
      --good-has 'classes=5 ' --bad-lacks 'WARN: classfile-facts: invalid' -- env RSDD_CLASSFACTS_MAX_ENTRIES=abc python3 @SUT@ classfile-facts "$FX/facts.jar"
    # The bite IS the ValueError crash from int('\xb2'): narrow the forbidden output so only that crash counts.
    FX_BAD_RC=1 FX_BAD_LACKS='ImportError|ModuleNotFoundError' fx_tooth env-ascii 's/re\.fullmatch(r"\[0-9\]+", raw)/raw.isdigit()/' \
      --good-has 'classes=5 ' --bad-has 'ValueError' -- env RSDD_CLASSFACTS_MAX_ENTRIES=$'\xc2\xb2' python3 @SUT@ classfile-facts "$FX/facts.jar"
    FX_BAD_RC=2 fx_tooth cli-dispatch 's/raw\[:1\] == \["classfile-facts"\]/raw[:1] == ["classfile-facts-x"]/' \
      --good-has '^CLASSFILE ' --bad-lacks '^CLASSFILE ' -- python3 @SUT@ classfile-facts "$FX/facts.jar"
    fx_tooth report-facts 's/^            "class_facts": facts, "class_facts_summary": summarize_facts(facts),$/            "class_facts_summary": summarize_facts(facts),/' \
      --good-has '^REPORT: class_facts=5 summary=True$' --bad-has '^REPORT: class_facts=0 ' -- run_facts_main @SUT@
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
