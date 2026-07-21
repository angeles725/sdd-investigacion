#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../corroborate-firmware.sh"; MANIFEST="$HERE/../analysis_manifest.py"
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in bwrap binwalk; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: corroborate-firmware tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$ROOT/fixture.bin" --output "$1" "${@:2}"; }
fake(){ mkdir -p "$ROOT/$1"; cat >"$ROOT/$1/binwalk"; chmod +x "$ROOT/$1/binwalk"; }

cat >"$ROOT/fixture.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f)fclose(f);}
int main(void){return 0;}
C
gcc -O0 -o "$ROOT/fixture.bin" "$ROOT/fixture.c"
printf '\x89PNG\r\n\x1a\n' >>"$ROOT/fixture.bin"

if run "$ROOT/a" && run "$ROOT/b" && cmp -s "$ROOT/a/firmware-static.v1.json" "$ROOT/b/firmware-static.v1.json" \
  && cmp -s "$ROOT/a/engine/signatures.json" "$ROOT/b/engine/signatures.json" \
  && cmp -s "$ROOT/a/engine/entropy.json" "$ROOT/b/engine/entropy.json" && [ ! -e "$ROOT/TARGET_EXECUTED" ]; then
  ok "real Binwalk 2.3.3 evidence is deterministic and never executes the fixture"
else no "real deterministic static evidence"; fi
if python3 - "$ROOT/a/firmware-static.v1.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]).parent; d=json.load(open(sys.argv[1])); e=d['engine']
assert d['schema']=='firmware-static.v1' and d['status']=='complete' and e['version']=='2.3.3'
assert e['argv']==['engine/binwalk','-B','-E','-N','input/firmware.bin']
argv=json.load(open(p/'engine/analysis-manifest.v1.json'))['argv']; assert argv[argv.index('--cap-drop'):argv.index('--cap-drop')+2]==['--cap-drop','ALL']
assert e['launcher']['source']['path']=='/usr/bin/binwalk' and e['launcher']['source']['sha256']==e['launcher']['staged']['sha256']
assert d['isolation']['profile']=={'name':'bubblewrap-static-network-denied','network_access':False,'static_only':True,'target_execution':False}
assert not any(x.name.startswith('_') or (x.name!='binwalk' and x.suffix not in ('.bin','.txt','.json')) for x in p.rglob('*') if x.is_file())
PY
then ok "report binds official staged launcher, fixed argv, and truthful isolation"; else no "report contract"; fi
if python3 - "$ROOT/a" <<'PY'
import json,pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1]); a=json.load(open(p/'engine/analysis-manifest.v1.json'))['argv']; prefix=a[:a.index('--')+1]
r=subprocess.run(prefix+['/bin/sh','-c',"! grep -Eq '^Cap(Inh|Prm|Eff|Bnd|Amb):.*[1-9a-fA-F]' /proc/self/status"],cwd=p)
assert r.returncode==0
PY
then ok "real Bubblewrap prefix drops every capability"; else no "Bubblewrap capability drop"; fi
if python3 "$MANIFEST" validate "$ROOT/a/engine/analysis-manifest.v1.json" && python3 "$MANIFEST" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
  ok "manifest validates and verifies"; else no "manifest verification"; fi

ln -s "$ROOT/fixture.bin" "$ROOT/link.bin"
mkdir "$ROOT/pathbad"; ln -s /usr/bin/true "$ROOT/pathbad/binwalk"
if ! "$SUT" --input "$ROOT/link.bin" --output "$ROOT/link-out" 2>/dev/null && ! run "$ROOT/fixture.bin" 2>/dev/null \
  && ! PATH="$ROOT/pathbad:/usr/bin:/bin" run "$ROOT/path-mismatch" 2>/dev/null; then ok "symlink, collision, and PATH disagreement fail closed"
else no "preflight safety"; fi
printf 12345 >"$ROOT/oversized.bin"; truncate -s 1048576 "$ROOT/sparse.bin"
if ! "$SUT" --input "$ROOT/oversized.bin" --output "$ROOT/oversized-out" --max-input-bytes 4 2>/dev/null \
  && ! "$SUT" --input "$ROOT/sparse.bin" --output "$ROOT/sparse-out" --max-input-bytes 4 2>/dev/null \
  && [ ! -e "$ROOT/oversized-out" ] && [ ! -e "$ROOT/sparse-out" ]; then ok "dense and sparse oversized inputs reject without output"
else no "input byte cap rejection"; fi
mkdir "$ROOT/.occupied.stage"; echo keep >"$ROOT/.occupied.stage/sentinel"
if ! run "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/.occupied.stage/sentinel" ]; then ok "foreign stage is preserved"; else no "stage collision"; fi

fake swapped <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vtest-original'; sleep 1; exit; }
printf '0 0x0 ORIGINAL signature\n64 0x40 Rising entropy edge (0.97)\n'
SH
boundary="$(stat -c %s "$ROOT/fixture.bin")"; PATH="$ROOT/swapped:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/swapped/binwalk" run "$ROOT/swap" --max-input-bytes "$boundary" & pid=$!
sleep .2; printf '#!/bin/sh\necho REPLACEMENT\n' >"$ROOT/swapped/new"; chmod +x "$ROOT/swapped/new"; mv "$ROOT/swapped/new" "$ROOT/swapped/binwalk"; wait "$pid"; rc=$?
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["engine"]["version"]=="test-original" and d["signatures"][0]["description"]=="ORIGINAL signature" and d["engine"]["test_override"] and d["caps"]["max_input_bytes"]==int(sys.argv[2])' "$ROOT/swap/firmware-static.v1.json" "$boundary"; then
  ok "exact input boundary succeeds and cap is recorded"; else no "input boundary contract"; fi

fake capped <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
printf '0 0x0 first\n1 0x1 second\n2 0x2 third\n'
SH
if PATH="$ROOT/capped:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/capped/binwalk" run "$ROOT/partial" --max-findings 2; [ "$?" -eq 1 ] \
  && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="partial" and d["counts"]=={"entropy_total":0,"findings_emitted":2,"findings_total":3,"signatures_total":3}' "$ROOT/partial/firmware-static.v1.json"; then
  ok "finding cap publishes truthful partial evidence"; else no "finding cap"; fi
fake child <<SH
#!/bin/sh
[ "\$1" = --help ] && { echo 'Binwalk vfake'; exit; }
(sleep 2; touch "$ROOT/LEAKED_CHILD") &
sleep 5
SH
if ! PATH="$ROOT/child:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/child/binwalk" run "$ROOT/failed" --max-processes 1 && sleep 3 \
  && [ ! -e "$ROOT/LEAKED_CHILD" ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="failed" and "process-cap" in d["errors"]' "$ROOT/failed/firmware-static.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/failed" "$ROOT/failed/engine/analysis-manifest.v1.json"; then
  ok "process cap is verifiable and the complete process tree is cleaned"; else no "process cap cleanup"; fi

fake noisy <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
dd if=/dev/zero bs=1M count=1 2>/dev/null
SH
if ! PATH="$ROOT/noisy:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/noisy/binwalk" run "$ROOT/noisy-out" --max-diagnostic-bytes 4096 \
  && [ "$(wc -c <"$ROOT/noisy-out/engine/stdout.txt")" -le 4096 ] && grep -q diagnostic-cap "$ROOT/noisy-out/firmware-static.v1.json"; then
  ok "1MiB output is execution-time bounded by a 4KiB file cap"; else no "diagnostic cap"; fi
if python3 - "$HERE/../corroborate_firmware.py" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); p=pathlib.Path('/safe/out')
for kind in ('ext4','xfs','btrfs','tmpfs','overlay'): f.require_private(p,f'1 0 0:1 / /safe rw - {kind} disk rw')
for kind in ('drvfs','9p','nfs4','fuse.sshfs','virtiofs','mystery'):
 try: f.require_private(p,f'1 0 0:1 / /safe rw - {kind} disk rw'); raise AssertionError(kind)
 except f.FirmwareError: pass
f.os.geteuid=lambda: 0
assert f.main(['--input','x','--output','y','--manifest-cli','z'])==2
PY
then ok "filesystem allowlist and root execution fail closed"; else no "filesystem/caller safety"; fi
fake slow <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
sleep 1; echo '0 0x0 staged source'
SH
before="$(sha256sum "$ROOT/fixture.bin"|cut -d' ' -f1)"; PATH="$ROOT/slow:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/slow/binwalk" run "$ROOT/source-swap" & pid=$!
for _ in $(seq 1 300); do [ "$(stat -c %a "$ROOT/.source-swap.stage/input/firmware.bin" 2>/dev/null)" = 400 ] && break; sleep .01; done
printf mutation >>"$ROOT/fixture.bin"; wait "$pid"; rc=$?
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["input"]["source"]["sha256"]=="sha256:"+sys.argv[2]==d["input"]["staged"]["sha256"]' "$ROOT/source-swap/firmware-static.v1.json" "$before"; then
  ok "source replacement cannot alter staged analysis bytes"; else no "source staging"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
