#!/usr/bin/env bash
# tests/ghidra-exporter.test.sh — CuratedEvidenceExporter.java test suite (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based schema/cap/isolation assertions. No Ghidra spawn.
#                    Always emits "== N passed · N failed ==".
#   slow           — real Ghidra run; requires Ghidra 12.1.x, gcc, python3, java21.
#   all            — both fast and slow paths.
#
# ANTI-#128 NOTE — do NOT remove or move these slow-only guards to fast lane:
#   - no-exec MARKER check: verifies that target code is NEVER executed by Ghidra
#   - clean-home check: verifies synthetic home dirs remain clean after run
#   - -deleteProject: verifies Ghidra cleans up its project dir
#   - rejection runs: malformed/oversized/collision/relative inputs must fail-closed
#   These cannot be exercised without a real Ghidra execution. Erasing them is the
#   #128 regression: a guard that is never triggered is theater, not a test.
#
# Schema v1 (ghidra-curated-evidence.v1) is host-path-free by design — the exporter
# does NOT record isolation booleans (containment is Ghidra-internal, not in schema).
# Only the no-host-path guard moves to fast lane; execution/clean-home/rejection stay slow.
#
# Exit 2 when the SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
EXPORTER="$TOOLBELT/ghidra/CuratedEvidenceExporter.java"

# Source lane helper (idempotent; aborts on invalid RSDD_TEST_LANE value).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the exporter source does not exist yet.
[ -f "$EXPORTER" ] || { echo "FATAL: SUT not found: $EXPORTER" >&2; exit 2; }

pass=0; fail=0
# One EXIT trap for both temp dirs (a later `trap` would REPLACE this one): the slow lane's ROOT
# and the --prove-teeth _MUT are both created later and both start empty.
ROOT=""; _MUT=""
_cleanup(){ [ -z "$ROOT" ] || rm -rf -- "$ROOT"; [ -z "$_MUT" ] || rm -rf -- "$_MUT"; }
trap _cleanup EXIT
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Determine active lane (aborts on invalid value per §7 anti-silent-zero).
_lane="$(rsdd_lane)"

# Fixture paths resolved here; existence checked in fast section.
_FULL_FIX="$(rsdd_lane_fixture ghidra-exporter full)"
_CAPPED_FIX="$(rsdd_lane_fixture ghidra-exporter capped)"
_LONG_FIX="$(rsdd_lane_fixture ghidra-exporter long)"

# ---------------------------------------------------------------------------
# SLOW LANE — real Ghidra run (tool required)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  # Tool availability check — resolves Ghidra and Java from tool-env helpers.
  # shellcheck source=../lib/tool-env.sh
  source "$TOOLBELT/lib/tool-env.sh"
  _GHIDRA_HOME="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
  _JAVA21="$(rsdd_resolve_java_home 2>/dev/null || true)"

  _slow_skip=0
  _SLOW_CASES=(S1 S2 S3 S4 S5 S6)   # the cases a version-gate SKIP reports, one line each
  if [ -z "$_GHIDRA_HOME" ] || [ -z "$_JAVA21" ] || ! rsdd_probe_ghidra "$_GHIDRA_HOME"; then
    echo "SLOW lane: usable Ghidra unavailable; slow-lane tests skipped." >&2
    _slow_skip=1
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    _version="$(awk -F= '$1=="application.version"{print $2}' \
      "$_GHIDRA_HOME/Ghidra/application.properties")"
    # The slow cases assert the exporter's behavior on a real run, not the Ghidra version
    # string, so any 12.1.x patch release is accepted (schema v1 is authored against the 12.1
    # program model). A different major.minor is environmental: typed SKIP, never FAIL (#1588).
    # An empty/unreadable application.version is a broken install, not an environment gap: FAIL.
    case "$_version" in
      "")
        no "slow: Ghidra application.version unreadable/empty in $_GHIDRA_HOME/Ghidra/application.properties (broken install)"
        _slow_skip=1 ;;
      12.1.*) ;;
      *)
        for _c in "${_SLOW_CASES[@]}"; do
          printf '  SKIP  slow %s real-Ghidra case: Ghidra 12.1.x required, found %s\n' "$_c" "$_version"
        done
        _slow_skip=1 ;;
    esac
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    for _tool in gcc python3 timeout; do
      command -v "$_tool" >/dev/null 2>&1 || {
        echo "SLOW lane: '$_tool' not found; slow-lane tests skipped." >&2
        _slow_skip=1; break
      }
    done
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then

    ROOT="$(mktemp -d)"   # removed by the single _cleanup EXIT trap installed above
    MARKER="$ROOT/TARGET_EXECUTED"

    cat >"$ROOT/fixture.c" <<'EOF'
#include <stdio.h>
int fixture_global=17;
__attribute__((constructor)) static void forbidden(void){FILE*f=fopen("TARGET_EXECUTED","w");if(f){fputs("executed",f);fclose(f);}}
__attribute__((visibility("default"))) int exported_add(int n){return n+fixture_global;}
static int named_helper(int n){return exported_add(n)+1;}
const char *long_evidence="CURATED_LONG_STRING_ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz_0123456789_repeat_repeat_repeat";
int main(void){puts(long_evidence);return named_helper(1)==19?0:1;}
EOF
    gcc -O0 -rdynamic -fno-pie -no-pie -o "$ROOT/fixture.elf" "$ROOT/fixture.c"

    _run_headless(){
      local run="$1" output="$2"; shift 2
      mkdir -p "$ROOT/$run/project" "$ROOT/$run/home" \
               "$ROOT/$run/xdg-cache" "$ROOT/$run/xdg-config"
      (cd "$ROOT" && \
        HOME="$ROOT/$run/home" XDG_CACHE_HOME="$ROOT/$run/xdg-cache" \
        XDG_CONFIG_HOME="$ROOT/$run/xdg-config" \
        JAVA_HOME="$_JAVA21" JAVA_TOOL_OPTIONS="-Duser.home=$ROOT/$run/home" \
        timeout 180 "$_GHIDRA_HOME/support/analyzeHeadless" \
          "$ROOT/$run/project" curated \
          -import "$ROOT/fixture.elf" -analysisTimeoutPerFile 120 \
          -scriptPath "$TOOLBELT/ghidra" \
          -postScript CuratedEvidenceExporter.java "$output" "$@" \
          -deleteProject \
          >"$ROOT/$run/headless.log" 2>&1)
      local rc=$?; printf '%s\n' "$rc" >"$ROOT/$run/headless.rc"; return "$rc"
    }

    _run_export(){
      local run="$1" rc; shift
      _run_headless "$run" "$ROOT/$run/evidence.json" "$@"; rc=$?
      [ "$rc" -eq 0 ] && [ -f "$ROOT/$run/evidence.json" ]
    }

    # S1: Determinism — two identical runs produce byte-identical output.
    if _run_export one 4096 4096 4096 4096 4096 4096 256 \
      && _run_export two 4096 4096 4096 4096 4096 4096 256 \
      && cmp -s "$ROOT/one/evidence.json" "$ROOT/two/evidence.json" \
      && [ ! -e "$MARKER" ]; then
      ok "slow S1: real Ghidra export is deterministic and target code is never executed"
    else
      no "slow S1: real Ghidra deterministic static export"
    fi
    [ -f "$ROOT/one/evidence.json" ] || {
      printf '%s\n' "--- first headless log ---"
      while IFS= read -r _line; do printf '%s\n' "$_line"; done <"$ROOT/one/headless.log"
    }

    # S2: Full report — schema, metadata, evidence fields.
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
    then ok "slow S2: full report has canonical metadata and representative evidence"
    else no "slow S2: full report contract"
    fi

    # S3: Caps — stop traversal, disclose record and string truncation.
    if _run_export capped 1 1 1 1 1 1 16 && python3 - "$ROOT/capped/evidence.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8')); kinds=('functions','symbols','imports','exports','strings','references')
assert d['status']=='partial' and d['caps']=={k:1 for k in kinds}|{'string_chars':16}
for k in kinds:
 c=d['counts'][k]; assert c['emitted']==1 and c['observed']==2 and not c['exact'] and d['truncation'][k]
dynamic=[d['program'],*sum((d[k] for k in kinds),[])]
assert all(len(v)<=16 for item in dynamic for v in item.values() if isinstance(v,str))
assert any(x['value_truncated'] for x in d['strings']) and d['string_values_truncated']>0
PY
    then ok "slow S3: caps stop traversal and disclose record and string truncation"
    else no "slow S3: cap and truncation behavior"
    fi

    # S4: Long string — bounded with explicit truncation, count exact.
    if _run_export long 4096 4096 4096 4096 4096 4096 32 && python3 - "$ROOT/long/evidence.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
matches=[x for x in d['strings'] if x['value'].startswith('CURATED_LONG_STR')]
assert len(matches)==1 and matches[0]['value_truncated'] and len(matches[0]['value'])==32
assert d['counts']['strings']['exact'] and d['string_values_truncated']>0 and d['status']=='partial'
PY
    then ok "slow S4: long fixture string is bounded with explicit truncation"
    else no "slow S4: long-string truncation"
    fi

    # S5: Clean-home — projects deleted and synthetic homes remain clean.
    # ANTI-#128: this guard MUST stay slow-only.
    _clean=1
    for _run in one two capped long; do
      [ -z "$(find "$ROOT/$_run/project" -mindepth 1 -print -quit 2>/dev/null)" ] || _clean=0
      [ -z "$(find "$ROOT/$_run/home" -mindepth 1 -print -quit 2>/dev/null)" ] || _clean=0
    done
    if [ "$_clean" = 1 ]; then
      ok "slow S5: projects are deleted and synthetic homes remain clean"
    else
      no "slow S5: project or home cleanup"
    fi

    # S6: Rejection runs — fail-closed for malformed, oversized, collision, relative output.
    # ANTI-#128: rejection runs MUST stay slow-only (require a real Ghidra process).
    _project_deleted(){ [ -z "$(find "$ROOT/$1/project" -mindepth 1 -print -quit 2>/dev/null)" ]; }
    _reject_new(){
      local run="$1" output="$2" expected rc; shift 2
      case "$output" in /*) expected="$output";; *) expected="$ROOT/$output";; esac
      _run_headless "$run" "$output" "$@"; rc=$?
      [ "$rc" -eq 0 ] && [ "$(<"$ROOT/$run/headless.rc")" = 0 ] \
        && [ ! -e "$expected" ] && _project_deleted "$run"
    }
    _rejected=1
    _reject_new rejected-relative relative.json 1 1 1 1 1 1 1 || _rejected=0
    _reject_new rejected-zero "$ROOT/zero.json" 0 1 1 1 1 1 1 || _rejected=0
    _reject_new rejected-malformed "$ROOT/malformed.json" nope 1 1 1 1 1 1 || _rejected=0
    printf 'sentinel\n' >"$ROOT/collision.json"; cp "$ROOT/collision.json" "$ROOT/collision.before"
    _run_headless rejected-collision "$ROOT/collision.json" 1 1 1 1 1 1 1; _collision_rc=$?
    if [ "$_rejected" = 1 ] && [ "$_collision_rc" -eq 0 ] \
      && [ "$(<"$ROOT/rejected-collision/headless.rc")" = 0 ] \
      && cmp -s "$ROOT/collision.before" "$ROOT/collision.json" \
      && _project_deleted rejected-collision; then
      ok "slow S6: rejections publish nothing, preserve collisions, delete projects"
    else
      no "slow S6: fail-closed rejection contract"
    fi

  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based assertions (sub-second; no Ghidra spawn)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: fixtures must exist before asserting against them.
  for _fix in "$_FULL_FIX" "$_CAPPED_FIX" "$_LONG_FIX"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite ghidra-exporter" >&2
      exit 1
    fi
  done

  # T1-fast: canonical re-encode equality — the headline guarantee.
  # CuratedEvidenceExporter.java emits compact sorted JSON + trailing LF.
  # The round-trip assertion proves the fixture itself is canonical bytes.
  if python3 - "$_FULL_FIX" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
d = json.loads(raw)
canonical = (json.dumps(d, ensure_ascii=False, sort_keys=True, separators=(',',':')) + '\n').encode()
assert raw.endswith(b'\n'), "fixture must end with LF"
assert raw == canonical, "fixture bytes are not canonical compact JSON+LF"
assert d['schema'] == 'ghidra-curated-evidence.v1' and d['status'] == 'complete'
assert d['analysis'] == {'timed_out': False}
assert d['program']['format'] == 'Executable and Linking Format (ELF)'
assert d['program']['image_base'] == '00400000'
assert d['program']['md5'] and d['program']['language'] and d['program']['compiler']
assert any(x['name'] == 'exported_add' for x in d['functions'])
assert any('puts' in x['name'] for x in d['imports'])
assert any(x['name'] == 'fixture_global' for x in d['symbols'])
assert any(x['name'] == 'exported_add' for x in d['exports'])
assert any('CURATED_LONG_STRING' in x['value'] for x in d['strings'])
assert d['references']
assert all(v['exact'] and v['observed'] == v['emitted'] for v in d['counts'].values())
assert not any(d['truncation'].values())
assert d['errors'] == [] and isinstance(d['warnings'], list) and d['limitations']
PY
  then ok "T1-fast: canonical re-encode equality + full schema assertions (fixture)"
  else no "T1-fast: canonical re-encode equality (fixture)"
  fi

  # T2-fast: cap-truthfulness — emitted/observed/exact/truncation consistency.
  if python3 - "$_CAPPED_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
kinds = ('functions', 'symbols', 'imports', 'exports', 'strings', 'references')
assert d['status'] == 'partial', f"expected partial, got {d['status']!r}"
assert d['caps'] == {k: 1 for k in kinds} | {'string_chars': 16}, f"caps mismatch: {d['caps']}"
for k in kinds:
    c = d['counts'][k]
    assert c['emitted'] == 1, f"{k}: emitted={c['emitted']} (expected 1)"
    assert c['observed'] == 2, f"{k}: observed={c['observed']} (expected 2)"
    assert not c['exact'],     f"{k}: exact must be false"
    assert d['truncation'][k], f"{k}: truncation must be true"
dynamic = [d['program'], *sum((d[k] for k in kinds), [])]
assert all(len(v) <= 16 for item in dynamic for v in item.values() if isinstance(v, str)), \
    "some string value exceeds 16 chars"
assert any(x['value_truncated'] for x in d['strings']), "no value_truncated=true in strings"
assert d['string_values_truncated'] > 0, "string_values_truncated must be > 0"
PY
  then ok "T2-fast: cap-truthfulness — emitted/observed/exact/truncation consistency (fixture)"
  else no "T2-fast: cap-truthfulness (fixture)"
  fi

  # T3-fast: string length-bounding — CURATED_LONG_STRING bounded at string_chars=32.
  if python3 - "$_LONG_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
matches = [x for x in d['strings'] if x['value'].startswith('CURATED_LONG_STR')]
assert len(matches) == 1,                    f"expected 1 CURATED_LONG_STR match, got {len(matches)}"
assert matches[0]['value_truncated'],        "value_truncated must be true"
assert len(matches[0]['value']) == 32,       f"expected len=32, got {len(matches[0]['value'])}"
assert d['counts']['strings']['exact'],      "counts.strings.exact must be true"
assert d['string_values_truncated'] > 0,    "string_values_truncated must be > 0"
assert d['status'] == 'partial',             f"expected partial, got {d['status']!r}"
PY
  then ok "T3-fast: string length-bounding — CURATED_LONG_STRING capped at 32 chars (fixture)"
  else no "T3-fast: string length-bounding (fixture)"
  fi

  # T4-fast: no-host-path guard — schema v1 must be host-path-free.
  _path_clean=1
  for _fix in "$_FULL_FIX" "$_CAPPED_FIX" "$_LONG_FIX"; do
    if python3 - "$_fix" <<'PY'
import sys
raw = open(sys.argv[1], encoding='utf-8').read()
for token in raw.split('"'):
    if '/home/' in token or '/tmp/' in token:
        print(f"LEAK: {token!r}", file=sys.stderr)
        sys.exit(1)
PY
    then : ; else _path_clean=0; fi
  done
  if [ "$_path_clean" = 1 ]; then
    ok "T4-fast: no-host-path guard — schema v1 is host-path-free (all fixtures)"
  else
    no "T4-fast: no-host-path guard (fixture leak detected)"
  fi

fi # fast | all

# ---------------------------------------------------------------------------
# --prove-teeth: fixture-mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: fixture-mutation controls --"
  # lib/mutant.sh is sourced only on this path; every helper the controls call is probed.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _fn in mutant_built mutant_tooth; do
    declare -F "$_fn" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_fn" >&2; exit 2; }
  done
  # The SUT of these controls is a JSON fixture, not a shell script: skip the `bash -n` check.
  # Each mutant is validated as JSON by its own builder (json.loads round-trip) instead.
  # MUTANT_SYNTAX=none is scoped per call in mk() below, never exported (#1814)
  _MUT="$(mktemp -d)"   # removed by the single _cleanup EXIT trap installed above

  mk(){ MUTANT_SYNTAX=none mutant_built "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

  # Checkers: the same assertions the fast lane runs on the same fixture artifact (T1-fast and
  # T2-fast), re-stated so each prints ONE typed line. A crash (bad JSON, missing key) prints a
  # Traceback and no RESULT line, so it never reads as a bite.
  # Exit codes: 0 = every assertion held (RESULT=ok); 1 = an assertion failed (RESULT=assert-fail:<msg>).
  _CHK_T2='
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    kinds = ("functions", "symbols", "imports", "exports", "strings", "references")
    assert d["status"] == "partial", "status not partial"
    assert d["caps"] == {k: 1 for k in kinds} | {"string_chars": 16}, "caps mismatch"
    for k in kinds:
        c = d["counts"][k]
        assert c["emitted"] == 1, "emitted != 1"
        assert c["observed"] == 2, "observed != 2"
        assert not c["exact"], "exact must be false"
        assert d["truncation"][k], "truncation must be true"
    dynamic = [d["program"], *sum((d[k] for k in kinds), [])]
    assert all(len(v) <= 16 for item in dynamic for v in item.values() if isinstance(v, str)), "string too long"
    assert any(x["value_truncated"] for x in d["strings"]), "no value_truncated"
    assert d["string_values_truncated"] > 0, "string_values_truncated not > 0"
except AssertionError as e:
    print("RESULT=assert-fail:" + str(e)); sys.exit(1)
print("RESULT=ok")
'
  _CHK_T1='
import json, pathlib, sys
try:
    raw = pathlib.Path(sys.argv[1]).read_bytes()
    d = json.loads(raw)
    canonical = (json.dumps(d, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    assert raw.endswith(b"\n"), "fixture must end with LF"
    assert raw == canonical, "fixture bytes are not canonical compact JSON+LF"
    assert d["schema"] == "ghidra-curated-evidence.v1" and d["status"] == "complete", "schema/status"
    assert d["analysis"] == {"timed_out": False}, "analysis"
    assert d["program"]["format"] == "Executable and Linking Format (ELF)", "format"
    assert d["program"]["image_base"] == "00400000", "image_base"
    assert d["program"]["md5"] and d["program"]["language"] and d["program"]["compiler"], "program fields"
    assert any(x["name"] == "exported_add" for x in d["functions"]), "functions"
    assert any("puts" in x["name"] for x in d["imports"]), "imports"
    assert any(x["name"] == "fixture_global" for x in d["symbols"]), "symbols"
    assert any(x["name"] == "exported_add" for x in d["exports"]), "exports"
    assert any("CURATED_LONG_STRING" in x["value"] for x in d["strings"]), "strings"
    assert d["references"], "references"
    assert all(v["exact"] and v["observed"] == v["emitted"] for v in d["counts"].values()), "counts"
    assert not any(d["truncation"].values()), "truncation"
    assert d["errors"] == [] and isinstance(d["warnings"], list) and d["limitations"], "errors/warnings/limitations"
except AssertionError as e:
    print("RESULT=assert-fail:" + str(e)); sys.exit(1)
print("RESULT=ok")
'

  # Tooth A: flip counts.*.exact false->true in a capped copy. T2 requires not c['exact'].
  mkdir -p "$_MUT/a"
  if ! python3 -c "
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
for k in d['counts']:
    d['counts'][k]['exact'] = True
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(d, ensure_ascii=False, sort_keys=True, separators=(',',':')) + '\n')
" "$_CAPPED_FIX" "$_MUT/a/capped.json"; then
    no "teeth-A: mutant build script failed"
  elif mk teeth-A "$_CAPPED_FIX" "$_MUT/a/capped.json"; then
    tt "teeth-A: T2-fast goes RED when counts.*.exact flipped true (cap-truthfulness bites)" 0 1 \
      "$_MUT/a/capped.json" --orig "$_CAPPED_FIX" \
      --good-has '^RESULT=ok$' --bad-has '^RESULT=assert-fail:exact must be false$' \
      --bad-lacks 'Traceback|Error' -- python3 -c "$_CHK_T2" @SUT@
  fi

  # Tooth B: drop the trailing LF from a full-fixture copy. T1 requires raw.endswith(b'\n').
  mkdir -p "$_MUT/b"
  if ! python3 -c "
import pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
assert raw.endswith(b'\n'), 'fixture must end with LF'
pathlib.Path(sys.argv[2]).write_bytes(raw[:-1])
" "$_FULL_FIX" "$_MUT/b/full_no_lf.json"; then
    no "teeth-B: mutant build script failed"
  elif mk teeth-B "$_FULL_FIX" "$_MUT/b/full_no_lf.json"; then
    tt "teeth-B: T1-fast goes RED when trailing LF dropped (canonical re-encode bites)" 0 1 \
      "$_MUT/b/full_no_lf.json" --orig "$_FULL_FIX" \
      --good-has '^RESULT=ok$' --bad-has '^RESULT=assert-fail:fixture must end with LF$' \
      --bad-lacks 'Traceback|Error' -- python3 -c "$_CHK_T1" @SUT@
  fi

  echo "-- prove-teeth done --"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
