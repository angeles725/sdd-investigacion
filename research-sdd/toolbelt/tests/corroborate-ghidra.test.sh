#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../corroborate-ghidra.sh"; MAN="$HERE/../analysis_manifest.py"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }; expect_no(){ local n=$1; shift; if ! "$@" >/dev/null 2>&1 && [ ! -e "$ROOT/$n" ]; then ok "$n"; else no "$n"; fi; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in bwrap java; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: corroborate-ghidra tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

mkdir -p "$ROOT/gh/support" "$ROOT/gh/Ghidra/Framework/Utility/lib" "$ROOT/jdk/bin" "$ROOT/bin"
printf 'application.name=Ghidra\napplication.version=12.1-test\n' >"$ROOT/gh/Ghidra/application.properties"
for f in support/launch.sh support/launch.properties support/LaunchSupport.jar Ghidra/Framework/Utility/lib/Utility.jar; do printf '%s\n' "$f" >"$ROOT/gh/$f"; done
cat >"$ROOT/jdk/bin/java" <<'SH'; chmod 755 "$ROOT/jdk/bin/java"
#!/bin/sh
[ "${1:-}" = -version ] && { echo 'openjdk version "21.0.1"' >&2; exit 0; }; exit 0
SH
cp "$ROOT/jdk/bin/java" "$ROOT/jdk/bin/javap"
cat >"$ROOT/bin/bwrap" <<PY; chmod 755 "$ROOT/bin/bwrap"
#!/usr/bin/env python3
import os,sys
root='$ROOT'; swap=root+'/bin/bwrap.swap'
if os.path.exists(root+'/swap-enabled') and os.path.exists(swap): os.replace(swap,root+'/bin/bwrap')
gate=root+'/gate'
if os.path.exists(root+'/gate-enabled'):
 open(gate+'.ready','w').close()
 for _ in range(1000):
  if os.path.exists(gate+'.go'): break
  import time; time.sleep(.01)
a=sys.argv[1:]; maps=[]; env=os.environ.copy(); i=0; cwd=None
while i<len(a) and a[i]!='--':
 o=a[i]; n=2 if o in ('--ro-bind','--bind','--setenv') else 1 if o in ('--proc','--dev','--tmpfs','--dir','--chdir') else 0
 if o in ('--ro-bind','--bind'): maps.append((a[i+2],a[i+1]))
 if o=='--setenv': env[a[i+1]]=a[i+2]
 if o=='--chdir': cwd=a[i+1]
 i+=1+n
i+=1
def m(x):
 for guest,host in sorted(maps,key=lambda x:-len(x[0])):
  if x==guest or x.startswith(guest+'/'): return host+x[len(guest):]
 return x
env['PATH']=':'.join(os.path.dirname(m(x+'/java')) if x=='/jdk/bin' else m(x) for x in env['PATH'].split(':'))
os.chdir(m(cwd) if cwd else os.getcwd()); os.execvpe(m(a[i]),[m(x) for x in a[i:]],env)
PY
mkheadless(){ cat >"$ROOT/gh/support/analyzeHeadless" <<SH
#!/bin/sh
[ "\${1:-}" = -help ] && { echo 'Headless Analyzer Usage'; exit 0; }
java --adapter-probe || exit 8
mode=$1; out=''; log=''; scriptlog=''; prev=''
for x in "\$@"; do [ "\$prev" = -postScript ] && shift; [ "\$prev" = CuratedEvidenceExporter.java ] && out="\$x"; [ "\$prev" = -log ] && log="\$x"; [ "\$prev" = -scriptlog ] && scriptlog="\$x"; prev="\$x"; done
printf 'stdout\n'; printf 'log\n' >"\$log"; printf 'scriptlog\n' >"\$scriptlog"
[ '$1' = loglink ] && { rm -f "\$log"; ln -s "$ROOT/outside.log" "\$log"; exit 9; }
case '$1' in timeout) sleep 4;; nonzero) exit 9;; descendant) sleep 30 & echo \$! >"$ROOT/child.pid"; exit 9;; missing) :;; malformed) printf '{bad' >"\$out";; sentinel) printf 'RSDD-SENTINEL' >"\$out";; flood) yes x | head -c 100000;; *) python3 - "\$out" <<'PY'
import json,sys
caps={'functions':2,'symbols':2,'imports':2,'exports':2,'strings':2,'references':2,'string_chars':32}; names=list(caps)[:6]
d={'schema':'ghidra-curated-evidence.v1','status':'complete','program':{'name':'target.bin','format':'ELF','language':'x','compiler':'x','image_base':'0','md5':'0'},'analysis':{'timed_out':False},'caps':caps,'truncation':{n:False for n in names},'counts':{n:{'emitted':0,'observed':0,'exact':True} for n in names},'string_values_truncated':0,'warnings':[],'errors':[],'limitations':['static']}
for n in names:d[n]=[]
if '$1' in ('partial','dishonest'):
 d['truncation']['functions']=True; d['counts']['functions']={'emitted':0,'observed':1,'exact':False}
if '$1'=='partial':d['status']='partial'
if '$1'=='boolean':d['counts']['functions']['emitted']=False
open(sys.argv[1],'w').write(json.dumps(d,separators=(',',':'))+'\n')
PY
esac
SH
chmod 755 "$ROOT/gh/support/analyzeHeadless"; }
run(){ local out=$1; [[ "$out" = /* ]] || out="$ROOT/$out"; ANALYZE_HEADLESS="$ROOT/gh/support/analyzeHeadless" JAVA_HOME="$ROOT/jdk" RSDD_BWRAP="${RSDD_BWRAP:-$ROOT/bin/bwrap}" RSDD_MANIFEST_CLI="${RSDD_MANIFEST_CLI:-$MAN}" RSDD_TEST_ONLY_UNTRUSTED_BWRAP="${RSDD_TEST_ONLY_UNTRUSTED_BWRAP-1}" "$SUT" --input "$ROOT/target.bin" --output "$out" --timeout-seconds "${2:-2}" --max-diagnostic-bytes "${3:-2000}" --max-functions 2 --max-strings 2 --max-references 2 --max-string-chars 32; }
cat >"$ROOT/target.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f)fclose(f);}
int main(void){return 0;}
C
gcc -o "$ROOT/target.bin" "$ROOT/target.c"
mkheadless good
if run good && python3 "$MAN" verify --root "$ROOT/good" "$ROOT/good/analysis-manifest.v1.json" && python3 - "$ROOT/good/report.json" "$ROOT/good/analysis-manifest.v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2])); assert d['status']=='complete' and d['ghidra']['version']=='12.1-test'
i=d['isolation']; assert i['network_access'] is True and i['target_execution'] is False
assert i['read_only_host_root'] is False and i['new_session'] is False and i['synthetic_user_state'] is False; assert len(d['provenance'])==10
assert 'manifest_identity' not in d['ghidra'] and 'report.json' in {x['path'] for x in m['outputs']}
assert {x['path'] for x in m['tool']['artifacts']}=={x['staged']['path'] for x in d['provenance']} - {'tool/bwrap'}
assert all(m['argv'][x['argv_index']-1]=='--ro-bind' for x in m['tool']['artifacts'])
assert not any(x.startswith('RSDD_PROVENANCE_') for x in m['argv'])
PY
then [ ! -e "$ROOT/TARGET_EXECUTED" ] && ok 'complete evidence binds staged chain without target execution' || no 'target execution'; else no 'complete evidence binds staged launch chain'; fi
ln -s "$ROOT/target.bin" "$ROOT/link"; expect_no input-symlink env ANALYZE_HEADLESS="$ROOT/gh/support/analyzeHeadless" JAVA_HOME="$ROOT/jdk" RSDD_BWRAP="$ROOT/bin/bwrap" RSDD_GHIDRA_EXPORTER="$ROOT/exporter.java" "$SUT" --input "$ROOT/link" --output "$ROOT/input-symlink"
ln -s nowhere "$ROOT/out-link"; expect_no out-link run out-link
mkdir "$ROOT/collision"; echo keep >"$ROOT/collision/keep"; if ! run collision >/dev/null 2>&1 && [ "$(cat "$ROOT/collision/keep")" = keep ]; then ok collision; else no collision; fi
mkdir "$ROOT/.foreign.stage"; echo keep >"$ROOT/.foreign.stage/keep"; expect_no foreign run foreign
for mode in nonzero missing malformed sentinel flood timeout; do mkheadless "$mode"; if run "$mode" 1 100 >/dev/null 2>&1; then rc=0; else rc=$?; fi; if [ "$rc" -ne 0 ] && [ -f "$ROOT/$mode/report.json" ] && [ ! -e "$ROOT/.$mode.stage" ]; then ok "$mode publishes failed evidence and cleans"; else no "$mode publishes failed evidence and cleans"; fi; done
mkheadless loglink; printf '%0100d\n' 0 >"$ROOT/outside.log"; outside_sum="$(sha256sum "$ROOT/outside.log")"; if ! run loglink 2 20 >/dev/null 2>&1 && [ "$(sha256sum "$ROOT/outside.log")" = "$outside_sum" ] && [ ! -e "$ROOT/loglink" ]; then ok 'sandbox log symlink cannot modify outside file'; else no 'sandbox log symlink safety'; fi
mkheadless partial; if run partial && python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["status"]=="partial"' "$ROOT/partial/report.json"; then ok 'truthful partial evidence'; else no 'truthful partial evidence'; fi
mkheadless dishonest; if ! run dishonest >/dev/null 2>&1 && python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["errors"]==["malformed-curated-output"]' "$ROOT/dishonest/report.json"; then ok 'dishonest output is failed'; else no 'dishonest output is failed'; fi
mkheadless good; if ! RSDD_BWRAP=/bin/false run sandbox >/dev/null 2>&1 && [ ! -e "$ROOT/sandbox" ]; then ok 'sandbox failure publishes nothing'; else no 'sandbox failure publishes nothing'; fi
mkheadless timeout; run swapped 3 >/dev/null 2>"$ROOT/swap.err" & pid=$!; _swapped_arrived=0; for _ in $(seq 1 300); do [ "$(stat -c %a "$ROOT/.swapped.stage/tool/ghidra/support/analyzeHeadless" 2>/dev/null)" = 500 ] && _swapped_arrived=1 && break; sleep .01; done
if [ "$_swapped_arrived" -eq 0 ]; then wait "$pid" 2>/dev/null || true; no 'source and tool swaps cannot change staged bytes — swap precondition did not arrive within deadline'; else printf 'changed\n' >"$ROOT/target.bin"; printf 'replacement\n' >"$ROOT/gh/support/analyzeHeadless"; wait "$pid"; rc=$?; if [ "$rc" -ne 0 ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["input"]["source"]["sha256"]==d["input"]["staged"]["sha256"]' "$ROOT/swapped/report.json"; then ok 'source and tool swaps cannot change staged bytes'; else cat "$ROOT/swap.err"; no 'source and tool swap resistance'; fi; fi
mkheadless timeout; run publication-race 1 >/dev/null 2>&1 & pid=$!; _pub_arrived=0; for _ in $(seq 1 300); do [ -e "$ROOT/.publication-race.stage/tool/ghidra/support/analyzeHeadless" ] && _pub_arrived=1 && break; sleep .01; done
if [ "$_pub_arrived" -eq 0 ]; then wait "$pid" 2>/dev/null || true; no 'publication race replaces nothing — publication precondition did not arrive within deadline'; else mkdir "$ROOT/publication-race"; echo keep >"$ROOT/publication-race/keep"; wait "$pid"; rc=$?; if [ "$rc" -eq 2 ] && [ "$(cat "$ROOT/publication-race/keep")" = keep ] && [ ! -e "$ROOT/.publication-race.stage" ]; then ok 'publication race replaces nothing'; else no 'publication race'; fi; fi
if [ "$(findmnt -T /mnt/c -n -o FSTYPE 2>/dev/null)" = 9p ]; then expect_no shared run "/mnt/c/rsdd-ghidra-$$"; else ok 'shared filesystem rejection (not mounted)'; fi
mv "$ROOT/jdk/bin/java" "$ROOT/jdk/bin/java.real"; ln -s java.real "$ROOT/jdk/bin/java"; mkheadless good; if run java-link; then ok 'canonical Java symlink chain'; else no 'canonical Java symlink chain'; fi; rm "$ROOT/jdk/bin/java"; mv "$ROOT/jdk/bin/java.real" "$ROOT/jdk/bin/java"
chmod 777 "$ROOT/jdk/bin/java"; expect_no unsafe-java run unsafe-java; chmod 755 "$ROOT/jdk/bin/java"
if RSDD_TEST_ONLY_UNTRUSTED_BWRAP=0 RSDD_BWRAP="$ROOT/bin/bwrap" run untrusted-bwrap >/dev/null 2>&1; then no 'user-owned Bubblewrap trust rejection'; else ok 'user-owned Bubblewrap rejected outside test mode'; fi
if RSDD_TEST_ONLY_UNTRUSTED_BWRAP=0 RSDD_BWRAP=/usr/bin/bwrap run real-bwrap && python3 -c 'import json,sys;i=json.load(open(sys.argv[1]))["isolation"];assert i["network_access"] is False and i["read_only_host_root"] is True and i["new_session"] is True and i["synthetic_user_state"] is True' "$ROOT/real-bwrap/report.json"; then ok 'real Bubblewrap mounts and staged launch'; else no 'real Bubblewrap mounts and staged launch'; fi
if RSDD_TEST_ONLY_UNTRUSTED_BWRAP=0 RSDD_BWRAP=/bin/true run fake-isolation >/dev/null 2>&1; then no 'unrelated root launcher isolation rejection'; else ok 'unrelated root launcher cannot claim isolation'; fi
mkheadless descendant; run descendant >/dev/null 2>&1; child=$(cat "$ROOT/child.pid"); if ! kill -0 "$child" 2>/dev/null; then ok 'nonzero exit reaps process group'; else kill "$child" 2>/dev/null; no 'nonzero exit reaps process group'; fi
mkheadless good; touch "$ROOT/gate-enabled"; run staged-swap >/dev/null 2>&1 & pid=$!; while [ ! -e "$ROOT/gate.ready" ]; do sleep .01; done; mv "$ROOT/.staged-swap.stage/tool/ghidra/support/analyzeHeadless" "$ROOT/held"; printf '#!/bin/sh\ntouch %s/CONSUMED_REPLACEMENT\nexit 9\n' "$ROOT" >"$ROOT/.staged-swap.stage/tool/ghidra/support/analyzeHeadless"; chmod 500 "$ROOT/.staged-swap.stage/tool/ghidra/support/analyzeHeadless"; touch "$ROOT/gate.go"; wait "$pid"; rm "$ROOT/gate-enabled"; if [ ! -e "$ROOT/CONSUMED_REPLACEMENT" ] && [ ! -e "$ROOT/staged-swap" ]; then ok 'staged pathname replacement is not consumed and is rejected'; else no 'staged pathname replacement resistance'; fi
mkheadless good; cp "$ROOT/bin/bwrap" "$ROOT/bin/bwrap.swap"; printf '#!/bin/sh\ntouch %s/LAUNCHER_REPLACEMENT\nexit 9\n' "$ROOT" >"$ROOT/bin/bwrap.swap"; chmod 755 "$ROOT/bin/bwrap.swap"; touch "$ROOT/swap-enabled"; run launcher-copy >/dev/null 2>&1; if [ ! -e "$ROOT/LAUNCHER_REPLACEMENT" ] && python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));r=json.load(open(sys.argv[2]));assert m["tool"]["launcher"]["sha256"]==r["isolation"]["launcher"]["sha256"]' "$ROOT/launcher-copy/analysis-manifest.v1.json" "$ROOT/launcher-copy/report.json"; then ok 'Bubblewrap staged digest binds execution and manifest'; else no 'Bubblewrap stable manifest identity'; fi; cp "$ROOT/launcher-copy/tool/bwrap" "$ROOT/bin/bwrap"; rm "$ROOT/swap-enabled"
mkheadless boolean; if ! run boolean >/dev/null 2>&1 && python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["errors"]==["malformed-curated-output"]' "$ROOT/boolean/report.json"; then ok 'boolean integer field rejected'; else no 'strict boolean integer typing'; fi
printf '%s\n' '#!/usr/bin/env python3' 'import os,sys' "if sys.argv[1]=='create' and os.path.exists('$ROOT/manifest.swap'): os.replace('$ROOT/manifest.swap','$ROOT/manifest.py')" "os.execv(sys.executable,[sys.executable,'$MAN',*sys.argv[1:]])" >"$ROOT/manifest.py"
printf '#!/bin/sh\ntouch %s/MANIFEST_REPLACEMENT\nexit 9\n' "$ROOT" >"$ROOT/manifest.swap"; chmod 755 "$ROOT/manifest.py" "$ROOT/manifest.swap"; mkheadless good; if RSDD_MANIFEST_CLI="$ROOT/manifest.py" run manifest-copy >/dev/null 2>&1 && [ ! -e "$ROOT/MANIFEST_REPLACEMENT" ]; then ok 'manifest CLI consumed through stable copy'; else no 'manifest CLI stable copy'; fi
mkheadless good; run trust-stage-race >/dev/null 2>&1 & pid=$!; while [ ! -e "$ROOT/.trust-stage-race.stage/input/target.bin" ]; do sleep .001; done; mv "$ROOT/gh/support/analyzeHeadless" "$ROOT/gh/support/analyzeHeadless.old"; printf '#!/bin/sh\ntouch %s/TRUST_SWAP_EXECUTED\n' "$ROOT" >"$ROOT/gh/support/analyzeHeadless"; chmod 755 "$ROOT/gh/support/analyzeHeadless"; wait "$pid"; rc=$?; mv "$ROOT/gh/support/analyzeHeadless.old" "$ROOT/gh/support/analyzeHeadless"
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/TRUST_SWAP_EXECUTED" ] && [ ! -e "$ROOT/trust-stage-race" ]; then ok 'validated Ghidra swap before staging fails closed'; else no 'trust-to-staging swap rejection'; fi
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: arrival flags capture preconditions at break (TOCTOU fix) --"
  # Tooth 1: swap poll loop must export _swapped_arrived via flag-at-break (not re-check).
  # origin/main's silent fall-through never sets this variable; guard-with-recheck does not either.
  if [ "${_swapped_arrived:-UNSET}" = "UNSET" ]; then
    no "teeth: _swapped_arrived not set — swap poll loop missing flag-at-break (guard regresses to origin/main)"
  else
    ok "teeth: swap poll loop set _swapped_arrived=${_swapped_arrived} (flag-at-break present)"
  fi
  # Tooth 2: publication-race poll loop must export _pub_arrived via flag-at-break.
  if [ "${_pub_arrived:-UNSET}" = "UNSET" ]; then
    no "teeth: _pub_arrived not set — pub-race poll loop missing flag-at-break (guard regresses to origin/main)"
  else
    ok "teeth: pub-race poll loop set _pub_arrived=${_pub_arrived} (flag-at-break present)"
  fi
  # A third check was written here and removed before merge: it created a directory, flagged it at
  # break, deleted it, and asserted the flag survived. That demonstrates the flag PATTERN on a toy
  # loop; it observes nothing about the guards above, so no mutation of the shipped code can fail it.
  # The version of this block that shipped in the first attempt was entirely of that kind, and an
  # adversarial reviewer killed it by reverting lines 100-103 and watching all its assertions stay
  # green. Teeth 1 and 2 above are kept precisely because that same revert makes them RED: the
  # variables they read exist only when the flag-at-break guards are present.
fi
echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
