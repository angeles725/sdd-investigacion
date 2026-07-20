#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../corroborate-native.sh"; MANIFEST="$HERE/../analysis_manifest.py"
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; SHARED_OUT=""; trap '[ -z "$SHARED_OUT" ] || rm -rf -- "$SHARED_OUT"; rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$ROOT/fixture.elf" --output "$1" "${@:2}"; }
mkfake(){ mkdir -p "$ROOT/$1"; cat >"$ROOT/$1/r2"; chmod +x "$ROOT/$1/r2"; }

cat >"$ROOT/fixture.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f){fputs("bad",f);fclose(f);}}
static int helper(int n){return n+7;} int main(void){return helper(35)==42?0:1;}
C
gcc -O0 -g -fno-pie -no-pie -o "$ROOT/fixture.elf" "$ROOT/fixture.c"

if run "$ROOT/a" && run "$ROOT/b" && cmp -s "$ROOT/a/native-static.v1.json" "$ROOT/b/native-static.v1.json" \
  && [ ! -e "$ROOT/TARGET_EXECUTED" ]; then ok "real r2 output is deterministic and target is never executed"
else no "real r2 deterministic static analysis"; fi
if python3 - "$ROOT/a/native-static.v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); e=d['engine']; a=e['argv']
assert d['schema']=='native-static.v1' and d['status']=='complete' and d['counts']['functions_emitted']>0
assert all(x in a for x in ('-NN','-S','-x')) and not any(x in a for x in ('-d','-w','-i','-I','-p','-r','-R'))
assert e['launcher']['source']['sha256']==e['launcher']['staged']['sha256'] and d['input']['source']['sha256']==d['input']['staged']['sha256']
PY
then ok "report binds safe invocation and source/staged identities"; else no "report contract"; fi
if python3 "$MANIFEST" validate "$ROOT/a/engine/analysis-manifest.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then ok "manifest CLI validates and verifies exact artifacts"
else no "manifest verification"; fi

ln -s "$ROOT/fixture.elf" "$ROOT/link.elf"
if ! "$SUT" --input "$ROOT/link.elf" --output "$ROOT/link-out" 2>/dev/null \
  && ! run "$ROOT/fixture.elf" 2>/dev/null \
  && ! RSDD_R2=/usr/bin/true run "$ROOT/wrong-r2" 2>/dev/null; then ok "bad input, output collision, and unrelated launcher fail closed"
else no "preflight failures"; fi
mkfake race <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 original 1'; sleep 2; exit 0; }
echo '[{"name":"ORIGINAL","offset":1}]'
SH
old="$(sha256sum "$ROOT/race/r2"|cut -d' ' -f1)"
PATH="$ROOT/race:$PATH" RSDD_R2="$ROOT/race/r2" run "$ROOT/race-out" & pid=$!
for _ in $(seq 1 1000); do pgrep -f "$ROOT/race/r2 -v|engine/r2 -v" >/dev/null && break; sleep .005; done
cat >"$ROOT/race/r2.new" <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 replacement 2'; exit 0; }
echo '[{"name":"REPLACEMENT_EXECUTED","offset":2}]'
SH
chmod +x "$ROOT/race/r2.new"; mv "$ROOT/race/r2.new" "$ROOT/race/r2"; new="$(sha256sum "$ROOT/race/r2"|cut -d' ' -f1)"; wait "$pid"; rrc=$?
if [ "$rrc" -eq 0 ] && python3 "$MANIFEST" verify --root "$ROOT/race-out" "$ROOT/race-out/engine/analysis-manifest.v1.json" && python3 - "$ROOT/race-out" "$old" "$new" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); h,n=('sha256:'+x for x in sys.argv[2:]); r=json.loads((p/'native-static.v1.json').read_text()); m=json.loads((p/'engine/analysis-manifest.v1.json').read_text()); a=m['tool']['artifacts'][0]
assert h!=n and r['functions'][0]['name']=='ORIGINAL' and r['engine']['launcher']['source']['sha256']==h and r['engine']['launcher']['staged']['sha256']==h and a['path']=='engine/r2' and a['sha256']==h and (p/'engine/r2').stat().st_mode&0o777==0o500
PY
then ok "atomic launcher swap cannot change analyzed bytes or provenance"; else no "staged launcher provenance"; fi
mkdir "$ROOT/.occupied.stage"; echo keep >"$ROOT/.occupied.stage/sentinel"
if ! run "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/.occupied.stage/sentinel" ]; then ok "foreign staging directory is never removed"
else no "staging collision preservation"; fi
if [ "$(findmnt -T /mnt/c -n -o FSTYPE 2>/dev/null)" = 9p ]; then
  SHARED_OUT="/mnt/c/.rsdd-native-test-$$"
  if ! run "$SHARED_OUT" 2>"$ROOT/shared.err" && grep -q 'Linux-private' "$ROOT/shared.err"; then ok "Windows-shared output is rejected before staging"
  else no "Linux-private staging enforcement"; fi
else ok "Linux-private staging enforcement (no WSL shared mount)"; fi

mkdir "$ROOT/evilhome"; echo '!touch SHOULD_NOT_RUN' >"$ROOT/evilhome/.radare2rc"
if HOME="$ROOT/evilhome" run "$ROOT/no-config" && [ ! -e "$ROOT/evilhome/SHOULD_NOT_RUN" ]; then ok "user configuration is disabled"
else no "user configuration isolation"; fi

mkfake slow <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; sleep 1; echo '[]'
SH
before="$(sha256sum "$ROOT/fixture.elf"|cut -d' ' -f1)"
PATH="$ROOT/slow:$PATH" RSDD_R2="$ROOT/slow/r2" run "$ROOT/mutation" & pid=$!
for _ in $(seq 1 500); do [ "$(stat -c %a "$ROOT/.mutation.stage/input/target.bin" 2>/dev/null)" = 400 ] && break; sleep .01; done
printf '\nsource mutation\n' >>"$ROOT/fixture.elf"; wait "$pid"; mrc=$?
if [ "$mrc" -eq 0 ] && python3 - "$ROOT/mutation/native-static.v1.json" "$before" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['input']['source']['sha256']=='sha256:'+sys.argv[2]; assert d['input']['source']['sha256']==d['input']['staged']['sha256']
PY
then ok "source mutation after staging cannot change analyzed bytes"; else no "staging mutation resistance"; fi

mkfake many <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }
echo '[{"name":"z","offset":2},{"name":"a","offset":1}]'
SH
if PATH="$ROOT/many:$PATH" RSDD_R2="$ROOT/many/r2" run "$ROOT/capped" --max-functions 1; [ "$?" -eq 1 ] \
  && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]));assert d["status"]==m["completeness"]=="partial" and d["counts"]=={"functions_total":2,"functions_emitted":1} and d["truncated"]["functions"]' "$ROOT/capped/native-static.v1.json" "$ROOT/capped/engine/analysis-manifest.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/capped" "$ROOT/capped/engine/analysis-manifest.v1.json"; then ok "function cap is explicit partial evidence with non-complete exit"
else no "function cap"; fi

mkfake noisy <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }
yes x | head -c 100000
SH
if ! PATH="$ROOT/noisy:$PATH" RSDD_R2="$ROOT/noisy/r2" run "$ROOT/output-cap" --max-bytes 100 \
  && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "output-cap" in d["errors"]' "$ROOT/output-cap/native-static.v1.json" \
  && [ "$(wc -c <"$ROOT/output-cap/engine/stdout.txt")" -le 100 ]; then ok "output cap kills and bounds noisy analyzers"
else no "output cap"; fi

mkfake fail <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; echo '[]'; exit 9
SH
if ! PATH="$ROOT/fail:$PATH" RSDD_R2="$ROOT/fail/r2" run "$ROOT/failed" \
  && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="failed" and d["engine"]["run"]["exit_code"]==9' "$ROOT/failed/native-static.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/failed" "$ROOT/failed/engine/analysis-manifest.v1.json"; then ok "analyzer failure publishes truthful verifiable evidence"
else no "analyzer failure evidence"; fi

mkfake hang <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; sleep 5
SH
if ! PATH="$ROOT/hang:$PATH" RSDD_R2="$ROOT/hang/r2" run "$ROOT/timeout" --timeout-seconds 1 \
  && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="failed" and "timeout" in d["errors"]' "$ROOT/timeout/native-static.v1.json" \
  && [ ! -e "$ROOT/.timeout.stage" ]; then ok "timeout is bounded, published, and cleaned"
else no "timeout evidence"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
