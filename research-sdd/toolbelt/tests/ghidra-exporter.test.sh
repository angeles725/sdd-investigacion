#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; TOOLBELT="$HERE/.."; EXPORTER="$TOOLBELT/ghidra/CuratedEvidenceExporter.java"
# shellcheck source=../lib/tool-env.sh
source "$TOOLBELT/lib/tool-env.sh"
GHIDRA_HOME="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"; JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"
if [ -z "$GHIDRA_HOME" ] || [ -z "$JAVA21" ] || ! rsdd_probe_ghidra "$GHIDRA_HOME"; then
  echo "SKIP: usable Ghidra is unavailable"; exit 0
fi
version="$(awk -F= '$1=="application.version"{print $2}' "$GHIDRA_HOME/Ghidra/application.properties")"
[ "$version" = 12.1.2 ] || { echo "FAIL: expected Ghidra 12.1.2, found $version" >&2; exit 1; }
for tool in gcc python3 timeout; do command -v "$tool" >/dev/null || { echo "FAIL: missing $tool" >&2; exit 1; }; done
[ -f "$EXPORTER" ] || { echo "FAIL: exporter missing: $EXPORTER" >&2; exit 1; }

ROOT="$(mktemp -d)"; trap 'rm -rf -- "$ROOT"' EXIT; pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }; no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
MARKER="$ROOT/TARGET_EXECUTED"
cat >"$ROOT/fixture.c" <<EOF
#include <stdio.h>
int fixture_global=17;
__attribute__((constructor)) static void forbidden(void){FILE*f=fopen("TARGET_EXECUTED","w");if(f){fputs("executed",f);fclose(f);}}
__attribute__((visibility("default"))) int exported_add(int n){return n+fixture_global;}
static int named_helper(int n){return exported_add(n)+1;}
const char *long_evidence="CURATED_LONG_STRING_ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz_0123456789_repeat_repeat_repeat";
int main(void){puts(long_evidence);return named_helper(1)==19?0:1;}
EOF
gcc -O0 -rdynamic -fno-pie -no-pie -o "$ROOT/fixture.elf" "$ROOT/fixture.c"

run_headless(){
  local run="$1" output="$2"; shift 2; mkdir -p "$ROOT/$run/project" "$ROOT/$run/home" "$ROOT/$run/xdg-cache" "$ROOT/$run/xdg-config"
  (cd "$ROOT" && HOME="$ROOT/$run/home" XDG_CACHE_HOME="$ROOT/$run/xdg-cache" XDG_CONFIG_HOME="$ROOT/$run/xdg-config" \
    JAVA_HOME="$JAVA21" JAVA_TOOL_OPTIONS="-Duser.home=$ROOT/$run/home" \
    timeout 180 "$GHIDRA_HOME/support/analyzeHeadless" "$ROOT/$run/project" curated \
      -import "$ROOT/fixture.elf" -analysisTimeoutPerFile 120 -scriptPath "$TOOLBELT/ghidra" \
      -postScript CuratedEvidenceExporter.java "$output" "$@" -deleteProject \
      >"$ROOT/$run/headless.log" 2>&1)
  local rc=$?; printf '%s\n' "$rc" >"$ROOT/$run/headless.rc"; return "$rc"
}
run_export(){
  local run="$1" rc; shift; run_headless "$run" "$ROOT/$run/evidence.json" "$@"; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$ROOT/$run/evidence.json" ]
}

if run_export one 4096 4096 4096 4096 4096 4096 256 && run_export two 4096 4096 4096 4096 4096 4096 256 \
  && cmp -s "$ROOT/one/evidence.json" "$ROOT/two/evidence.json" && [ ! -e "$MARKER" ]; then
  ok "real Ghidra export is deterministic and target code is never executed"
else no "real Ghidra deterministic static export"; fi
[ -f "$ROOT/one/evidence.json" ] || { printf '%s\n' "--- first headless log ---"; while IFS= read -r line; do printf '%s\n' "$line"; done <"$ROOT/one/headless.log"; }

if python3 - "$ROOT/one/evidence.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); d=json.loads(raw)
assert raw.endswith(b'\n') and raw == (json.dumps(d,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode()
assert d['schema']=='ghidra-curated-evidence.v1' and d['status']=='complete'
assert d['analysis']=={'timed_out':False} and d['program']['format']=='Executable and Linking Format (ELF)'
assert d['program']['md5'] and d['program']['language'] and d['program']['compiler'] and d['program']['image_base']=='00400000'
assert any(x['name']=='exported_add' for x in d['functions'])
assert any('puts' in x['name'] for x in d['imports']) and any(x['name']=='fixture_global' for x in d['symbols'])
assert any(x['name']=='exported_add' for x in d['exports'])
assert any('CURATED_LONG_STRING' in x['value'] for x in d['strings']) and d['references']
assert all(v['exact'] and v['observed']==v['emitted'] for v in d['counts'].values())
assert not any(d['truncation'].values()) and d['errors']==[] and isinstance(d['warnings'],list) and d['limitations']
assert all('/home/' not in s and '/tmp/' not in s for s in raw.decode().split('"'))
PY
then ok "full report has canonical metadata and representative evidence"; else no "full report contract"; fi

if run_export capped 1 1 1 1 1 1 16 && python3 - "$ROOT/capped/evidence.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8')); kinds=('functions','symbols','imports','exports','strings','references')
assert d['status']=='partial' and d['caps']=={k:1 for k in kinds}|{'string_chars':16}
for k in kinds:
 c=d['counts'][k]; assert c['emitted']==1 and c['observed']==2 and not c['exact'] and d['truncation'][k]
dynamic=[d['program'],*sum((d[k] for k in kinds),[])]
assert all(len(v)<=16 for item in dynamic for v in item.values() if isinstance(v,str))
assert any(x['value_truncated'] for x in d['strings']) and d['string_values_truncated']>0
PY
then ok "caps stop traversal and disclose record and string truncation"; else no "cap and truncation behavior"; fi

if run_export long 4096 4096 4096 4096 4096 4096 32 && python3 - "$ROOT/long/evidence.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
matches=[x for x in d['strings'] if x['value'].startswith('CURATED_LONG_STR')]
assert len(matches)==1 and matches[0]['value_truncated'] and len(matches[0]['value'])==32
assert d['counts']['strings']['exact'] and d['string_values_truncated']>0 and d['status']=='partial'
PY
then ok "long fixture string is bounded with explicit truncation"; else no "long-string truncation"; fi

clean=1
for run in one two capped long; do
  [ -z "$(find "$ROOT/$run/project" -mindepth 1 -print -quit)" ] || clean=0
  [ -z "$(find "$ROOT/$run/home" -mindepth 1 -print -quit)" ] || clean=0
done
if [ "$clean" = 1 ]; then ok "projects are deleted and synthetic homes remain clean"; else no "project or home cleanup"; fi

project_deleted(){ [ -z "$(find "$ROOT/$1/project" -mindepth 1 -print -quit)" ]; }
reject_new(){
  local run="$1" output="$2" expected rc; shift 2
  case "$output" in /*) expected="$output";; *) expected="$ROOT/$output";; esac
  run_headless "$run" "$output" "$@"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(<"$ROOT/$run/headless.rc")" = 0 ] && [ ! -e "$expected" ] && project_deleted "$run"
}
rejected=1
reject_new rejected-relative relative.json 1 1 1 1 1 1 1 || rejected=0
reject_new rejected-zero "$ROOT/zero.json" 0 1 1 1 1 1 1 || rejected=0
reject_new rejected-malformed "$ROOT/malformed.json" nope 1 1 1 1 1 1 || rejected=0
printf 'sentinel\n' >"$ROOT/collision.json"; cp "$ROOT/collision.json" "$ROOT/collision.before"
run_headless rejected-collision "$ROOT/collision.json" 1 1 1 1 1 1 1; collision_rc=$?
if [ "$rejected" = 1 ] && [ "$collision_rc" -eq 0 ] && [ "$(<"$ROOT/rejected-collision/headless.rc")" = 0 ] \
  && cmp -s "$ROOT/collision.before" "$ROOT/collision.json" && project_deleted rejected-collision; then
  ok "rejections publish nothing, preserve collisions, delete projects, and expose Ghidra rc 0"
else no "fail-closed rejection contract"; fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
