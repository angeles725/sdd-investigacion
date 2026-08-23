#!/usr/bin/env bash
# tests/corroborate-native-r2.test.sh — corroborate-native-r2 adapter (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — live SAFE_R2 import teeth + fixture-based structural assertions.
#                    Always runs; no r2/gcc/bwrap spawn required.  Anti-#128 WIN.
#   slow           — integration tests with real r2 + gcc + bwrap.
#                    Skips with informational message when tools are absent.
#   all            — both lanes.
#
# Anti-#128 fix: FAST lane always runs; the old whole-suite skip on missing tools
#   is gone.  SLOW lane emits an informational message and skips cleanly when
#   r2/gcc/bwrap are absent.
# Exit 2 when SUT Python module is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT_SH="$TOOLBELT/corroborate-native.sh"
SUT_PY="$TOOLBELT/corroborate_native.py"
MAN="$TOOLBELT/analysis_manifest.py"

# Source lane helper (aborts on invalid RSDD_TEST_LANE value per §7 anti-silent-zero).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the SUT Python module does not exist yet.
[ -f "$SUT_PY" ] || { echo "FATAL: SUT module not found: $SUT_PY" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# Active lane (aborts on invalid RSDD_TEST_LANE value).
_lane="$(rsdd_lane)"

# Fixture paths (cwd-independent; existence validated in the fast-lane section).
_FIX_HAPPY="$(rsdd_lane_fixture corroborate-native-r2 happy)"
_FIX_CAPPED="$(rsdd_lane_fixture corroborate-native-r2 capped)"

_slow_skip=1  # default; set to 0 only when slow lane actually runs

# ---------------------------------------------------------------------------
# SLOW LANE — integration tests with real r2 + gcc + bwrap
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then
  _slow_skip=0
  for _cmd in r2 gcc bwrap; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done
  if [[ "$_slow_skip" -eq 0 ]] && [ ! -x "$SUT_SH" ]; then
    echo "SLOW lane: SUT shell wrapper not found: $SUT_SH" >&2; _slow_skip=1
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"
    SHARED_OUT=""
    # shellcheck disable=SC2064
    trap '[ -z "$SHARED_OUT" ] || rm -rf -- "$SHARED_OUT"; rm -rf "$ROOT"' EXIT

    run(){ "$SUT_SH" --input "$ROOT/fixture.elf" --output "$1" "${@:2}"; }
    mkfake(){ mkdir -p "$ROOT/$1"; cat >"$ROOT/$1/r2"; chmod +x "$ROOT/$1/r2"; }

    cat >"$ROOT/fixture.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f){fputs("bad",f);fclose(f);}}
static int helper(int n){return n+7;} int main(void){return helper(35)==42?0:1;}
C
    gcc -O0 -g -fno-pie -no-pie -o "$ROOT/fixture.elf" "$ROOT/fixture.c"

    if run "$ROOT/a" && run "$ROOT/b" \
      && cmp -s "$ROOT/a/native-static.v1.json" "$ROOT/b/native-static.v1.json" \
      && [ ! -e "$ROOT/TARGET_EXECUTED" ]; then
      ok "real r2 output is deterministic and target is never executed"
    else no "real r2 deterministic static analysis"; fi

    if python3 - "$ROOT/a/native-static.v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); e=d['engine']; a=e['argv']
assert d['schema']=='native-static.v1' and d['status']=='complete' and d['counts']['functions_emitted']>0
assert all(x in a for x in ('-NN','-S','-x')) and not any(x in a for x in ('-d','-w','-i','-I','-p','-r','-R'))
assert e['launcher']['source']['sha256']==e['launcher']['staged']['sha256'] and d['input']['source']['sha256']==d['input']['staged']['sha256']
PY
    then ok "report binds safe invocation and source/staged identities"
    else no "report contract"; fi

    if python3 "$MAN" validate "$ROOT/a/engine/analysis-manifest.v1.json" \
      && python3 "$MAN" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
      ok "manifest CLI validates and verifies exact artifacts"
    else no "manifest verification"; fi

    ln -s "$ROOT/fixture.elf" "$ROOT/link.elf"
    if ! "$SUT_SH" --input "$ROOT/link.elf" --output "$ROOT/link-out" 2>/dev/null \
      && ! run "$ROOT/fixture.elf" 2>/dev/null \
      && ! RSDD_R2=/usr/bin/true run "$ROOT/wrong-r2" 2>/dev/null; then
      ok "bad input, output collision, and unrelated launcher fail closed"
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
    chmod +x "$ROOT/race/r2.new"
    mv "$ROOT/race/r2.new" "$ROOT/race/r2"
    new="$(sha256sum "$ROOT/race/r2"|cut -d' ' -f1)"
    wait "$pid"; rrc=$?
    if [ "$rrc" -eq 0 ] \
      && python3 "$MAN" verify --root "$ROOT/race-out" "$ROOT/race-out/engine/analysis-manifest.v1.json" \
      && python3 - "$ROOT/race-out" "$old" "$new" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); h,n=('sha256:'+x for x in sys.argv[2:])
r=json.loads((p/'native-static.v1.json').read_text())
m=json.loads((p/'engine/analysis-manifest.v1.json').read_text())
a=m['tool']['artifacts'][0]
assert h!=n and r['functions'][0]['name']=='ORIGINAL'
assert r['engine']['launcher']['source']['sha256']==h and r['engine']['launcher']['staged']['sha256']==h
assert a['path']=='engine/r2' and a['sha256']==h and (p/'engine/r2').stat().st_mode&0o777==0o500
PY
    then ok "atomic launcher swap cannot change analyzed bytes or provenance"
    else no "staged launcher provenance"; fi

    mkdir "$ROOT/.occupied.stage"; echo keep >"$ROOT/.occupied.stage/sentinel"
    if ! run "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/.occupied.stage/sentinel" ]; then
      ok "foreign staging directory is never removed"
    else no "staging collision preservation"; fi

    if [ "$(findmnt -T /mnt/c -n -o FSTYPE 2>/dev/null)" = 9p ]; then
      SHARED_OUT="/mnt/c/.rsdd-native-test-$$"
      if ! run "$SHARED_OUT" 2>"$ROOT/shared.err" && grep -q 'Linux-private' "$ROOT/shared.err"; then
        ok "Windows-shared output is rejected before staging"
      else no "Linux-private staging enforcement"; fi
    else ok "Linux-private staging enforcement (no WSL shared mount)"; fi

    mkdir "$ROOT/evilhome"; echo '!touch SHOULD_NOT_RUN' >"$ROOT/evilhome/.radare2rc"
    if HOME="$ROOT/evilhome" run "$ROOT/no-config" && [ ! -e "$ROOT/evilhome/SHOULD_NOT_RUN" ]; then
      ok "user configuration is disabled"
    else no "user configuration isolation"; fi

    mkfake slow <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; sleep 1; echo '[]'
SH
    before="$(sha256sum "$ROOT/fixture.elf"|cut -d' ' -f1)"
    PATH="$ROOT/slow:$PATH" RSDD_R2="$ROOT/slow/r2" run "$ROOT/mutation" & pid=$!
    for _ in $(seq 1 500); do
      [ "$(stat -c %a "$ROOT/.mutation.stage/input/target.bin" 2>/dev/null)" = 400 ] && break
      sleep .01
    done
    printf '\nsource mutation\n' >>"$ROOT/fixture.elf"; wait "$pid"; mrc=$?
    if [ "$mrc" -eq 0 ] && python3 - "$ROOT/mutation/native-static.v1.json" "$before" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['input']['source']['sha256']=='sha256:'+sys.argv[2]
assert d['input']['source']['sha256']==d['input']['staged']['sha256']
PY
    then ok "source mutation after staging cannot change analyzed bytes"
    else no "staging mutation resistance"; fi

    mkfake many <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }
echo '[{"name":"z","offset":2},{"name":"a","offset":1}]'
SH
    if PATH="$ROOT/many:$PATH" RSDD_R2="$ROOT/many/r2" run "$ROOT/capped" --max-functions 1
    [ "$?" -eq 1 ] \
      && python3 -c \
        'import json,sys;d=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]));assert d["status"]==m["completeness"]=="partial" and d["counts"]=={"functions_total":2,"functions_emitted":1} and d["truncated"]["functions"]' \
        "$ROOT/capped/native-static.v1.json" "$ROOT/capped/engine/analysis-manifest.v1.json" \
      && python3 "$MAN" verify --root "$ROOT/capped" "$ROOT/capped/engine/analysis-manifest.v1.json"; then
      ok "function cap is explicit partial evidence with non-complete exit"
    else no "function cap"; fi

    mkfake noisy <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }
yes x | head -c 100000
SH
    if ! PATH="$ROOT/noisy:$PATH" RSDD_R2="$ROOT/noisy/r2" run "$ROOT/output-cap" --max-bytes 100 \
      && python3 -c \
        'import json,sys;d=json.load(open(sys.argv[1]));assert "output-cap" in d["errors"]' \
        "$ROOT/output-cap/native-static.v1.json" \
      && [ "$(wc -c <"$ROOT/output-cap/engine/stdout.txt")" -le 100 ]; then
      ok "output cap kills and bounds noisy analyzers"
    else no "output cap"; fi

    mkfake fail <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; echo '[]'; exit 9
SH
    if ! PATH="$ROOT/fail:$PATH" RSDD_R2="$ROOT/fail/r2" run "$ROOT/failed" \
      && python3 -c \
        'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="failed" and d["engine"]["run"]["exit_code"]==9' \
        "$ROOT/failed/native-static.v1.json" \
      && python3 "$MAN" verify --root "$ROOT/failed" "$ROOT/failed/engine/analysis-manifest.v1.json"; then
      ok "analyzer failure publishes truthful verifiable evidence"
    else no "analyzer failure evidence"; fi

    mkfake hang <<'SH'
#!/bin/sh
[ "${1:-}" = -v ] && { echo 'radare2 fake 1'; exit 0; }; sleep 5
SH
    if ! PATH="$ROOT/hang:$PATH" RSDD_R2="$ROOT/hang/r2" run "$ROOT/timeout" --timeout-seconds 1 \
      && python3 -c \
        'import json,sys;d=json.load(open(sys.argv[1]));assert d["status"]=="failed" and "timeout" in d["errors"]' \
        "$ROOT/timeout/native-static.v1.json" \
      && [ ! -e "$ROOT/.timeout.stage" ]; then
      ok "timeout is bounded, published, and cleaned"
    else no "timeout evidence"; fi

    # warn-native: rc=1 path emits stderr pointer (§7 anti-silent-zero)
    if ! PATH="$ROOT/fail:$PATH" RSDD_R2="$ROOT/fail/r2" run "$ROOT/failed-ptr" 2>"$ROOT/warn-native.err" \
      && grep -q 'native-static.v1' "$ROOT/warn-native.err" \
      && grep -q 'native-static.v1.json' "$ROOT/warn-native.err"; then
      ok "rc=1 path emits warn_evidence stderr pointer for native-static.v1"
    else no "rc=1 warn_evidence pointer in native stderr"; fi

  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — live SAFE_R2 import teeth + fixture-based structural assertions
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: both fixtures must exist before asserting.
  for _fix in "$_FIX_HAPPY" "$_FIX_CAPPED"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite corroborate-native-r2" >&2
      exit 1
    fi
  done

  # F1: SAFE_R2 live-import teeth — strongest fast-lane assertion.
  # Imports the real SUT module and checks the list directly; no subprocess.
  # Mutation control: SAFE_R2.append('-w') flips this assertion RED.
  # (FOOTGUN: SAFE_R2 += '-w' iterates the string; '-w' never enters the list.)
  if python3 - "$TOOLBELT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import corroborate_native
SAFE_R2 = corroborate_native.SAFE_R2
required = {'-NN', '-S', '-x'}
forbidden = {'-w', '-d', '-i', '-I', '-p', '-r', '-R'}
missing = required - set(SAFE_R2)
present_bad = forbidden & set(SAFE_R2)
assert missing == set(), \
    f"F1: required safe flags missing from SAFE_R2: {missing!r}"
assert present_bad == set(), \
    f"F1: forbidden flags present in SAFE_R2: {present_bad!r}"
print(f"OK: safe={sorted(required & set(SAFE_R2))} forbidden_absent={not bool(present_bad)}")
PY
  then ok "F1: SAFE_R2 live-import: safe flags present, forbidden flags absent"
  else no "F1: SAFE_R2 live-import (fast-lane teeth)"; fi

  # F2: happy fixture — schema, status, engine name, function count, no errors.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "native-static.v1", \
    f"F2: schema={d.get('schema')!r}"
assert d.get("status") == "complete", \
    f"F2: status={d.get('status')!r}"
assert d.get("engine", {}).get("name") == "radare2", \
    f"F2: engine.name={d.get('engine',{}).get('name')!r}"
counts = d.get("counts", {})
assert counts.get("functions_emitted", 0) >= 1, \
    f"F2: functions_emitted={counts.get('functions_emitted')!r}"
assert d.get("errors") == [], \
    f"F2: errors={d.get('errors')!r}"
assert d.get("truncated", {}).get("functions") is False, \
    f"F2: truncated.functions must be False"
print(f"OK: schema={d['schema']} status={d['status']} emitted={counts['functions_emitted']}")
PY
  then ok "F2: happy fixture: schema=native-static.v1, status=complete, engine=radare2"
  else no "F2: happy fixture structural assertions"; fi

  # F3: sha256 equality pairs + relative logical paths.
  # argv walk is a cheap STRUCTURAL invariant (all-relative by construction of SAFE_R2),
  # NOT anti-#128 teeth; the live-import in F1 is the bite.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
inp = d.get("input", {})
# sha256 equality: source == staged (same content, different roles)
assert inp["source"]["sha256"] == inp["staged"]["sha256"], \
    f"F3: input sha256 mismatch: {inp['source']['sha256']!r} != {inp['staged']['sha256']!r}"
lnch = d.get("engine", {}).get("launcher", {})
# sha256 equality: r2 source == staged (same binary, verified staging)
assert lnch["source"]["sha256"] == lnch["staged"]["sha256"], \
    f"F3: launcher sha256 mismatch: {lnch['source']['sha256']!r} != {lnch['staged']['sha256']!r}"
# logical (relative) paths preserved — must NOT be normalized away
assert inp["staged"]["path"] == "input/target.bin", \
    f"F3: staged input path={inp['staged']['path']!r}"
assert lnch["staged"]["path"] == "engine/r2", \
    f"F3: staged launcher path={lnch['staged']['path']!r}"
# argv structural invariant: all entries are relative or option strings (no abs paths)
argv = d.get("engine", {}).get("argv", [])
abs_in_argv = [x for x in argv if isinstance(x, str) and x.startswith("/")]
assert abs_in_argv == [], \
    f"F3 (structural): argv contains absolute paths: {abs_in_argv!r}"
sha_i = inp['source']['sha256']
sha_r = lnch['source']['sha256']
print(f"OK: sha_input={sha_i!r} sha_r2={sha_r!r} argv_clean={len(argv)} entries")
PY
  then ok "F3: sha256 equality pairs + relative logical paths + argv structural invariant"
  else no "F3: sha256 equality / path invariants (fixture)"; fi

  # F4: capped fixture — partial status, emitted=1, truncated=true.
  if python3 - "$_FIX_CAPPED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "partial", \
    f"F4: status={d.get('status')!r} (expected partial)"
counts = d.get("counts", {})
assert counts.get("functions_emitted") == 1, \
    f"F4: functions_emitted={counts.get('functions_emitted')!r}"
assert d.get("truncated", {}).get("functions") is True, \
    f"F4: truncated.functions must be True"
total = counts.get("functions_total", 0)
assert total >= 2, \
    f"F4: functions_total={total!r} (expected >= 2 from real r2 on fixture.elf)"
print(f"OK: status=partial emitted=1 total={total} truncated=True")
PY
  then ok "F4: capped fixture: status=partial, emitted=1, truncated=True"
  else no "F4: capped fixture structural assertions"; fi

fi # fast | all

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: corroborate-native-r2 mutation controls --"

  # teeth-SAFE_R2: mutate SAFE_R2 by appending '-w' via .append() →
  # the forbidden-flag check (F1) goes RED.
  # FOOTGUN NOTE: SAFE_R2 += '-w' iterates the string (appends '-' and 'w'
  # as separate characters); '-w' never appears → teeth would stay GREEN.
  # Always use .append('-w') or += ['-w'] for this mutation.
  _mut_dir="$(mktemp -d)"
  _mut_tooth_rc=0
  _MUTATION_MARKER='           "-e", "scr.interactive=false", "-c", "aaa;aflj", "input/target.bin"]'
  if ! grep -qF "$_MUTATION_MARKER" "$SUT_PY"; then
    no "teeth-SAFE_R2: mutation target not found in SUT (SUT changed?)"
  else
    # Step 1: write mutated copy with SAFE_R2.append('-w') after the list.
    python3 - "$SUT_PY" "$_mut_dir" "$TOOLBELT" <<'PY'
import sys, pathlib, shutil
sut   = pathlib.Path(sys.argv[1])
out   = pathlib.Path(sys.argv[2]) / "corroborate_native.py"
tb    = pathlib.Path(sys.argv[3])
old   = '           "-e", "scr.interactive=false", "-c", "aaa;aflj", "input/target.bin"]\n'
src   = sut.read_text()
assert old in src, "mutation target missing from source after re-read"
out.write_text(src.replace(old, old + "SAFE_R2.append('-w')  # mutant: inject forbidden flag\n", 1))
shutil.copytree(str(tb / 'lib'), str(out.parent / 'lib'))
PY
    _setup_rc=$?
    if [[ "$_setup_rc" -ne 0 ]]; then
      no "teeth-SAFE_R2: mutant setup failed (SUT changed?)"
    else
      # Step 2: import mutated module and run forbidden-flag check.
      python3 - "$_mut_dir" <<'PY' || _mut_tooth_rc=$?
import sys, importlib.util, pathlib
mut_dir = pathlib.Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location(
    "corroborate_native_mut", mut_dir / "corroborate_native.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SAFE_R2 = list(m.SAFE_R2)
forbidden = {'-w', '-d', '-i', '-I', '-p', '-r', '-R'}
present = forbidden & set(SAFE_R2)
if present:
    print(f"append('-w') inserted {sorted(present)} into SAFE_R2 — teeth bite", file=sys.stderr)
    sys.exit(1)   # RED → has teeth
else:
    print("SAFE_R2 still clean despite append('-w') — NO TEETH", file=sys.stderr)
    sys.exit(0)   # GREEN → no teeth
PY
      if [[ "$_mut_tooth_rc" -ne 0 ]]; then
        ok "teeth-SAFE_R2: append('-w') mutation → forbidden flag detected (bites)"
      else
        no "teeth-SAFE_R2: append('-w') mutation → check stayed GREEN (no teeth)"
      fi
    fi
  fi
  rm -rf "$_mut_dir"

  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
