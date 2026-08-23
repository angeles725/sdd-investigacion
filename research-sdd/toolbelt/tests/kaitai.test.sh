#!/usr/bin/env bash
# tests/kaitai.test.sh — kaitai-struct evidence adapter test suite (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based schema/cap/isolation assertions + unit tests.
#                    No ksc or kaitai-venv spawn.  Always emits "== N passed · N failed ==".
#   slow           — real tool run; requires kaitai-struct-compiler, bwrap, python3,
#                    and kaitai venv python ($RSDD_KAITAI_PY or default path).
#   all            — both fast and slow paths.
#
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT="$TOOLBELT/corroborate-kaitai.sh"
MANIFEST="$TOOLBELT/analysis_manifest.py"

# Source lane helper (idempotent; aborts on invalid RSDD_TEST_LANE value).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the script-under-test does not exist yet.
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --ksy "$2" --output "$3" "${@:4}"; }

# Determine active lane (aborts on invalid value per §7 anti-silent-zero).
_lane="$(rsdd_lane)"

# Fixture paths resolved here; existence checked in fast section.
_HAPPY_FIX="$(rsdd_lane_fixture kaitai happy)"
_CAPPED_FIX="$(rsdd_lane_fixture kaitai capped)"

# ---------------------------------------------------------------------------
# SLOW LANE — real kaitai run (tool required)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  _KAITAI_PY="${RSDD_KAITAI_PY:-$HOME/.local/share/rsdd-kaitai/bin/python}"
  _slow_skip=0
  for _cmd in bwrap python3 kaitai-struct-compiler; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done
  if [[ "$_slow_skip" -eq 0 ]] && ! [ -x "$_KAITAI_PY" ]; then
    echo "SLOW lane: kaitai venv python not found ($_KAITAI_PY); slow-lane tests skipped." >&2
    _slow_skip=1
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$ROOT"' EXIT

    # demo.ksy: magic(2B LE), count(u2 LE), value(u4 LE)
    cat > "$ROOT/demo.ksy" << 'EOKSY'
meta:
  id: demo
  endian: le
seq:
  - id: magic
    contents: [0x4b, 0x53]
  - id: count
    type: u2
  - id: value
    type: u4
EOKSY

    # sample.bin: KS + count=3 (u2 LE) + value=0xdeadbeef (u4 LE) = 8 bytes
    python3 -c "open('$ROOT/sample.bin', 'wb').write(b'KS\x03\x00\xef\xbe\xad\xde')"

    # wrong_magic.bin: same length as sample.bin but wrong magic
    python3 -c "open('$ROOT/wrong_magic.bin', 'wb').write(b'\x00\x00\x03\x00\xef\xbe\xad\xde')"

    # string_demo.ksy: magic(2B) + label(str 16B ASCII) — for value-bytes cap
    cat > "$ROOT/string_demo.ksy" << 'EOKSY'
meta:
  id: string_demo
  endian: le
seq:
  - id: magic
    contents: [0x4b, 0x53]
  - id: label
    type: str
    size: 16
    encoding: ASCII
EOKSY
    python3 -c "open('$ROOT/string_demo.bin', 'wb').write(b'KS' + b'0123456789ABCDEF')"

    # nested.ksy: two levels of nesting — for depth-cap
    cat > "$ROOT/nested.ksy" << 'EOKSY'
meta:
  id: nested_demo
  endian: le
types:
  point:
    seq:
      - id: x
        type: u1
      - id: y
        type: u1
  header:
    seq:
      - id: version
        type: u1
      - id: origin
        type: point
seq:
  - id: hdr
    type: header
  - id: count
    type: u1
EOKSY
    python3 -c "open('$ROOT/nested.bin', 'wb').write(bytes([1, 2, 3, 4]))"

    # malformed.ksy: invalid YAML
    printf 'meta:\n  id: bad\n  endian: le\nseq:\n  - id: \t\t[broken yaml\n' > "$ROOT/malformed.ksy"

    # imports.ksy: references a nonexistent imported struct
    cat > "$ROOT/imports.ksy" << 'EOKSY'
meta:
  id: imports_demo
  imports:
    - /nonexistent_import_xyz
  endian: le
seq:
  - id: val
    type: u1
EOKSY

    # repeat_demo.ksy: repeat-eos of u1 — parses every byte in input (for timeout)
    cat > "$ROOT/repeat_demo.ksy" << 'EOKSY'
meta:
  id: repeat_demo
  endian: le
seq:
  - id: data
    type: u1
    repeat: eos
EOKSY

    # T1: Happy path.
    _T1_OUT="$ROOT/out_t1"
    if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T1_OUT" --timeout 120 2>/dev/null \
      && [ -f "$_T1_OUT/kaitai-evidence.v1.json" ]; then
      ok "T1: happy path: evidence JSON produced"
    else
      no "T1: happy path"
    fi

    # T2: Evidence schema.
    if python3 - "$_T1_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "kaitai-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
s = d.get("structure", {})
assert "fields" in s and "counts" in s, "structure.fields/counts missing"
assert isinstance(s.get("truncated"), bool), "structure.truncated must be bool"
assert s.get("truncated") == False, f"expected truncated:false, got {s.get('truncated')}"
assert s.get("parse_error") is None, f"expected parse_error=null, got {s['parse_error']!r}"
for f in s.get("fields", []):
    assert "path" in f and "name" in f and "type" in f, f"field keys missing: {f}"
c = s["counts"]
assert c["total_fields"] >= 3, f"demo.ksy has 3 fields, got {c['total_fields']}"
cpl = d.get("compile", {})
assert "generated_parser" in cpl and "ksc_version" in cpl, "compile keys missing"
gp = cpl["generated_parser"]
assert gp.get("sha256", "").startswith("sha256:"), "generated_parser.sha256 bad"
assert d.get("ksy_identity", {}).get("sha256", "").startswith("sha256:"), "ksy_identity.sha256 bad"
assert d.get("runtime_version"), "runtime_version must be non-empty"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
print(f"OK: schema={d['schema']} status={d['status']} total={c['total_fields']}")
PY
    then ok "T2: evidence schema: fields, counts, ksy_identity, generated_parser.sha256, runtime_version"
    else no "T2: evidence schema"
    fi

    # T3: Determinism.
    _T3_OUT="$ROOT/out_t3"
    if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T3_OUT" --timeout 120 2>/dev/null \
      && cmp -s "$_T1_OUT/kaitai-evidence.v1.json" "$_T3_OUT/kaitai-evidence.v1.json"; then
      ok "T3: determinism: two runs produce byte-identical evidence"
    else
      no "T3: determinism"
    fi

    # T4: --max-fields 2 → sampled==2 < total==3, truncated:true + limitation.
    _T4_OUT="$ROOT/out_t4"
    if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T4_OUT" --max-fields 2 --timeout 120 2>/dev/null \
      && python3 - "$_T4_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]; c = s["counts"]; lims = d.get("limitations", [])
assert c["sampled"] == 2, f"expected sampled=2, got {c['sampled']}"
assert c["total_fields"] > c["sampled"], f"total > sampled expected"
assert s.get("truncated") == True, f"expected truncated:true"
cap_lim = any("field" in l.lower() or "max-fields" in l.lower() or "cap" in l.lower()
               for l in lims)
assert cap_lim, f"no field-cap limitation: {lims}"
print(f"OK: sampled=2 total={c['total_fields']} truncated=True limitation present")
PY
    then ok "T4: --max-fields 2: sampled<total, truncated:true, limitation recorded"
    else no "T4: --max-fields 2 field cap"
    fi

    # T5: --max-value-bytes 4 on long string → bounded value + full sha256 + truncated.
    _T5_OUT="$ROOT/out_t5"
    if run "$ROOT/string_demo.bin" "$ROOT/string_demo.ksy" "$_T5_OUT" \
        --max-value-bytes 4 --timeout 120 2>/dev/null \
      && python3 - "$_T5_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]
label = next((f for f in s.get("fields", []) if f["name"] == "label"), None)
assert label is not None, "label field not found"
v = label.get("value", {})
assert isinstance(v, dict), f"label value must be dict"
assert v.get("sha256", "").startswith("sha256:"), "sha256 prefix wrong"
assert len(v.get("value", "")) <= 4, f"value not bounded: {v.get('value')!r}"
assert v.get("value_truncated") == True, "value_truncated must be True"
assert s.get("truncated") == True, "structure.truncated must be True"
print(f"OK: label bounded, sha256 present, truncated=True")
PY
    then ok "T5: --max-value-bytes 4: str value bounded, sha256 present, truncated:true"
    else no "T5: --max-value-bytes 4 value cap"
    fi

    # T6: nested + --max-depth 1 → depth-cap flag, truncated.
    _T6_OUT="$ROOT/out_t6"
    if run "$ROOT/nested.bin" "$ROOT/nested.ksy" "$_T6_OUT" \
        --max-depth 1 --timeout 120 2>/dev/null \
      && python3 - "$_T6_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]
assert s.get("truncated") == True, f"expected truncated:true on depth cap"
lims = d.get("limitations", [])
assert any("depth" in l.lower() for l in lims), f"depth-cap limitation missing: {lims}"
print(f"OK: depth cap fired, truncated=True, depth-cap limitation present")
PY
    then ok "T6: nested + --max-depth 1: depth_cap flag, truncated:true"
    else no "T6: nested depth cap"
    fi

    # T7: Malformed .ksy → exit 2, no evidence.
    _T7_OUT="$ROOT/out_t7"; _T7_EXIT=0
    run "$ROOT/sample.bin" "$ROOT/malformed.ksy" "$_T7_OUT" --timeout 30 2>/dev/null \
      || _T7_EXIT=$?
    if [ "$_T7_EXIT" -eq 2 ] && [ ! -d "$_T7_OUT" ]; then
      ok "T7: malformed .ksy → exit 2, no evidence published"
    else
      no "T7: malformed .ksy (exit=$_T7_EXIT dir_exists=$([ -d "$_T7_OUT" ] && echo yes || echo no))"
    fi

    # T8: Wrong magic binary → exit 1, status:failed, error message, no traceback.
    _T8_OUT="$ROOT/out_t8"; _T8_EXIT=0
    run "$ROOT/wrong_magic.bin" "$ROOT/demo.ksy" "$_T8_OUT" --timeout 120 2>/dev/null \
      || _T8_EXIT=$?
    if [ "$_T8_EXIT" -eq 1 ] && [ -f "$_T8_OUT/kaitai-evidence.v1.json" ] \
      && python3 - "$_T8_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed"
text = json.dumps(d)
assert "Traceback" not in text, "traceback text found in evidence JSON"
pe = d.get("structure", {}).get("parse_error")
assert pe is not None, "parse_error must be set"
assert "Traceback" not in pe, f"traceback in parse_error"
print(f"OK: status=failed parse_error present no traceback")
PY
    then ok "T8: wrong-magic binary → exit 1, status:failed, error message, no traceback"
    else no "T8: wrong-magic binary handling (exit=$_T8_EXIT)"
    fi

    # T9: --timeout 1 with repeat-eos over ~64MiB → resource-cap.
    _T9_BIN="$ROOT/big.bin"
    python3 -c "
import sys
with open(sys.argv[1], 'wb') as f:
    chunk = bytes(65536)
    for _ in range(1024):
        f.write(chunk)
" "$_T9_BIN" 2>/dev/null
    _T9_OUT="$ROOT/out_t9"; _T9_EXIT=0
    run "$_T9_BIN" "$ROOT/repeat_demo.ksy" "$_T9_OUT" --timeout 1 2>/dev/null \
      || _T9_EXIT=$?
    if [ "$_T9_EXIT" -eq 0 ]; then
      echo "  SKIP  T9: run completed in <1s on 64MiB file (too fast; flake-proof skip)"
    elif [ "$_T9_EXIT" -eq 2 ]; then
      no "T9: adapter fatal error (exit 2)"
    elif [ -f "$_T9_OUT/kaitai-evidence.v1.json" ]; then
      if python3 - "$_T9_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed"
cap_errors = {"timeout", "memory-cap"}
assert any(e in cap_errors for e in d.get("errors", [])), f"no resource-cap in errors"
assert d.get("structure", {}).get("truncated") == True, "structure.truncated must be True"
lims = d.get("limitations", [])
assert any("timeout" in l or "memory-cap" in l for l in lims), "no resource-cap limitation"
print(f"OK: status=failed resource-cap in errors truncated=True")
PY
      then ok "T9: --timeout 1 on 64MiB: resource-cap in errors, truncated:true, limitation"
      else no "T9: resource-cap visibility"
      fi
    else
      no "T9: evidence not published after timeout (exit $_T9_EXIT)"
    fi

    # T9b: memory-cap signal — deterministic path.
    _T9B_BIN="$ROOT/big.bin"
    [ -f "$_T9B_BIN" ] || python3 -c "
import sys
with open(sys.argv[1], 'wb') as f:
    chunk = bytes(65536)
    for _ in range(1024):
        f.write(chunk)
" "$_T9B_BIN" 2>/dev/null
    _T9B_OUT="$ROOT/out_t9b"; _T9B_EXIT=0
    run "$_T9B_BIN" "$ROOT/repeat_demo.ksy" "$_T9B_OUT" \
        --timeout 60 --max-memory-mb 256 2>/dev/null \
      || _T9B_EXIT=$?
    if [ "$_T9B_EXIT" -eq 0 ]; then
      no "T9b: memory-cap path (driver exited 0, MemoryError not surfaced)"
    elif [ "$_T9B_EXIT" -eq 2 ]; then
      no "T9b: adapter fatal error (exit 2)"
    elif [ -f "$_T9B_OUT/kaitai-evidence.v1.json" ]; then
      if python3 - "$_T9B_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed"
assert "memory-cap" in d.get("errors", []), f"memory-cap not in errors: {d.get('errors')}"
assert d.get("structure", {}).get("truncated") == True, "structure.truncated must be True"
lims = d.get("limitations", [])
assert any("memory-cap" in l for l in lims), "no memory-cap limitation"
print(f"OK: memory-cap in errors truncated=True limitation present")
PY
      then ok "T9b: memory-cap signal surfaced as first-class resource limit"
      else no "T9b: memory-cap fidelity"
      fi
    else
      no "T9b: evidence not published after memory-cap (exit $_T9B_EXIT)"
    fi

    # T9c: read-time memory-cap (R4 guard).
    _T9C_OUT="$ROOT/out_t9c"; _T9C_EXIT=0
    run "$_T9B_BIN" "$ROOT/repeat_demo.ksy" "$_T9C_OUT" \
        --timeout 60 --max-memory-mb 80 2>/dev/null \
      || _T9C_EXIT=$?
    if [ "$_T9C_EXIT" -eq 0 ]; then
      no "T9c: adapter exit 0 on read-time memory-cap"
    elif [ "$_T9C_EXIT" -eq 2 ]; then
      no "T9c: adapter fatal error (exit 2)"
    elif [ -f "$_T9C_OUT/kaitai-evidence.v1.json" ]; then
      if python3 - "$_T9C_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed"
assert "memory-cap" in d.get("errors", []), f"memory-cap not in errors"
assert d.get("structure", {}).get("truncated") == True, "structure.truncated must be True"
lims = d.get("limitations", [])
assert any("memory-cap" in l for l in lims), "no memory-cap limitation"
PY
      then ok "T9c: read-time memory-cap surfaced as first-class resource limit"
      else no "T9c: read-time memory-cap fidelity"
      fi
    else
      no "T9c: evidence not published after read-time memory-cap (exit $_T9C_EXIT)"
    fi

    # T9d: walk-phase memory-cap guard (deterministic injection).
    _T9D_GEN="$_T1_OUT/engine/gen"
    _T9D_PY=$(ls "$_T9D_GEN"/*.py 2>/dev/null | head -1)
    if ! [ -f "${_T9D_PY:-}" ]; then
      echo "  SKIP  T9d: walk-phase memory-cap injection (T1 gen dir absent or empty)"
    else
      _T9D_STEM="${_T9D_PY##*/}"; _T9D_STEM="${_T9D_STEM%.py}"
      cat > "$ROOT/t9d_shim.py" << 'PYSHIM'
"""T9d injection shim: patches _walk to raise MemoryError, then runs main()."""
import sys, os
sys.path.insert(0, os.environ["KAITAI_DRIVER_DIR"])
import kaitai_driver

def _raise_walk_oom(*a, **kw):
    raise MemoryError("injected walk OOM for T9d")

kaitai_driver._walk = _raise_walk_oom
sys.exit(kaitai_driver.main())
PYSHIM

      _T9D_STDOUT="$ROOT/t9d_stdout.json"; _T9D_EXIT=0
      KAITAI_DRIVER_DIR="$TOOLBELT/lib" \
        "$_KAITAI_PY" "$ROOT/t9d_shim.py" \
          --module-dir "$_T9D_GEN" --stem "$_T9D_STEM" \
          --input "$ROOT/sample.bin" \
          >"$_T9D_STDOUT" 2>/dev/null \
        || _T9D_EXIT=$?

      if [ "$_T9D_EXIT" -ne 0 ]; then
        no "T9d: walk-phase memory-cap: driver exited $_T9D_EXIT (expected 0)"
      elif ! [ -s "$_T9D_STDOUT" ]; then
        no "T9d: walk-phase memory-cap: stdout empty"
      elif python3 - "$_T9D_STDOUT" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d.get("memory_cap") is True, f"memory_cap must be True"
assert d.get("truncated") is True, f"truncated must be True"
print(f"OK: memory_cap=True truncated=True (walk-phase injection)")
PY
      then
        ok "T9d: walk-phase MemoryError → memory-cap signal (monkeypatched _walk, exit 0)"
      else
        no "T9d: walk-phase memory-cap: unexpected JSON content"
      fi
    fi

    # T10: Output-dir-exists → fail-closed.
    mkdir -p "$ROOT/already_exists"; _T10_EXIT=0
    run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$ROOT/already_exists" --timeout 10 2>/dev/null \
      || _T10_EXIT=$?
    if [ "$_T10_EXIT" -ne 0 ] && [ ! -f "$ROOT/already_exists/kaitai-evidence.v1.json" ]; then
      ok "T10: output-dir-exists → fail-closed, no evidence published"
    else
      no "T10: output-dir-exists (exit=$_T10_EXIT)"
    fi

    # T11: Symlinked binary → exit 2; symlinked .ksy → exit 2.
    ln -s "$ROOT/sample.bin" "$ROOT/symlink_binary.bin"
    _T11a_EXIT=0
    run "$ROOT/symlink_binary.bin" "$ROOT/demo.ksy" "$ROOT/out_t11a" --timeout 10 2>/dev/null \
      || _T11a_EXIT=$?
    ln -s "$ROOT/demo.ksy" "$ROOT/symlink.ksy"
    _T11b_EXIT=0
    run "$ROOT/sample.bin" "$ROOT/symlink.ksy" "$ROOT/out_t11b" --timeout 10 2>/dev/null \
      || _T11b_EXIT=$?
    if [ "$_T11a_EXIT" -eq 2 ] && [ ! -d "$ROOT/out_t11a" ] \
      && [ "$_T11b_EXIT" -eq 2 ] && [ ! -d "$ROOT/out_t11b" ]; then
      ok "T11: symlinked binary → exit 2; symlinked .ksy → exit 2"
    else
      no "T11: symlink rejection (binary_exit=$_T11a_EXIT ksy_exit=$_T11b_EXIT)"
    fi

    # T13: Isolation recorded — network_access=false, manifest present.
    if python3 - "$_T1_OUT/kaitai-evidence.v1.json" "$_T1_OUT/engine/analysis-manifest.v1.json" <<'PY'
import json, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert profile.get("static_only") == True, f"static_only not True: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
assert Path(sys.argv[2]).is_file(), "analysis manifest not found"
print(f"OK: isolation profile={profile}, manifest exists")
PY
    then ok "T13: isolation recorded: network_access=false, manifest present"
    else no "T13: isolation profile"
    fi

    # T14: imports.ksy compile failure → exit 2, no evidence.
    _T14_OUT="$ROOT/out_t14"; _T14_EXIT=0
    run "$ROOT/sample.bin" "$ROOT/imports.ksy" "$_T14_OUT" --timeout 30 2>/dev/null \
      || _T14_EXIT=$?
    if [ "$_T14_EXIT" -eq 2 ] && [ ! -d "$_T14_OUT" ]; then
      ok "T14: imports.ksy compile failure → exit 2, no evidence"
    else
      no "T14: imports.ksy (exit=$_T14_EXIT dir_exists=$([ -d "$_T14_OUT" ] && echo yes || echo no))"
    fi

    # T15: .ksy > 1 MiB → exit 2.
    python3 -c "
import sys
with open(sys.argv[1], 'w') as f:
    f.write('meta:\n  id: toobig\nseq:\n')
    for i in range(55000):
        f.write(f'  # padding line {i}\n')
" "$ROOT/big.ksy" 2>/dev/null
    _T15_OUT="$ROOT/out_t15"; _T15_EXIT=0
    run "$ROOT/sample.bin" "$ROOT/big.ksy" "$_T15_OUT" --timeout 10 2>/dev/null \
      || _T15_EXIT=$?
    if [ "$_T15_EXIT" -eq 2 ] && [ ! -d "$_T15_OUT" ]; then
      ok "T15: .ksy > 1 MiB → exit 2, no evidence"
    else
      no "T15: .ksy size guard (exit=$_T15_EXIT dir_exists=$([ -d "$_T15_OUT" ] && echo yes || echo no))"
    fi

    # T16: engine/gen/<stem>.py + engine/driver.py + manifest verify.
    if python3 - "$_T1_OUT" "$MANIFEST" <<'PY'
import json, sys, subprocess
from pathlib import Path
out_dir = Path(sys.argv[1]); manifest_cli = sys.argv[2]
gen_dir = out_dir / "engine" / "gen"
gen_pys = list(gen_dir.glob("*.py"))
assert gen_pys, f"no .py in engine/gen/"
assert len(gen_pys) == 1, f"expected exactly 1 .py in gen/"
print(f"engine/gen/{gen_pys[0].name} exists")
driver = out_dir / "engine" / "driver.py"
assert driver.is_file(), "engine/driver.py missing"
print("engine/driver.py exists")
ev = json.load(open(out_dir / "kaitai-evidence.v1.json"))
gp_path = ev["compile"]["generated_parser"]["path"]
assert gp_path.startswith("engine/gen/"), f"unexpected path: {gp_path}"
assert (out_dir / gp_path).is_file(), f"{gp_path} not found"
print(f"compile.generated_parser.path={gp_path!r}")
manifest_path = str(out_dir / "engine" / "analysis-manifest.v1.json")
r1 = subprocess.run(["python3", manifest_cli, "validate", manifest_path],
                    capture_output=True, timeout=30)
assert r1.returncode == 0, f"manifest validate failed: {r1.stderr.decode()}"
r2 = subprocess.run(["python3", manifest_cli, "verify", "--root", str(out_dir),
                      manifest_path], capture_output=True, timeout=30)
assert r2.returncode == 0, f"manifest verify failed: {r2.stderr.decode()}"
print("analysis_manifest.py verify --root passed")
PY
    then ok "T16: engine/gen/<stem>.py + engine/driver.py in outputs; manifest verify passes"
    else no "T16: outputs list + manifest verify"
    fi
  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based assertions (no tool spawn; sub-second)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: fixtures must exist before asserting against them.
  for _fix in "$_HAPPY_FIX" "$_CAPPED_FIX"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite kaitai" >&2
      exit 1
    fi
  done

  # T2-fast: Evidence schema from fixture.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "kaitai-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
s = d.get("structure", {})
assert "fields" in s and "counts" in s, "structure.fields/counts missing"
assert isinstance(s.get("truncated"), bool), "structure.truncated must be bool"
assert s.get("truncated") == False, f"expected truncated:false"
assert s.get("parse_error") is None, f"expected parse_error=null"
c = s["counts"]
assert c["total_fields"] >= 3, f"demo.ksy has 3 fields, got {c['total_fields']}"
cpl = d.get("compile", {})
assert "generated_parser" in cpl and "ksc_version" in cpl, "compile keys missing"
gp = cpl["generated_parser"]
assert gp.get("sha256", "").startswith("sha256:"), "generated_parser.sha256 bad"
assert d.get("ksy_identity", {}).get("sha256", "").startswith("sha256:"), "ksy_identity.sha256 bad"
assert d.get("runtime_version"), "runtime_version must be non-empty"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
print(f"OK: schema={d['schema']} status={d['status']} total={c['total_fields']}")
PY
  then ok "T2-fast: evidence schema (fixture): fields, counts, compile.sha256, runtime_version"
  else no "T2-fast: evidence schema (fixture)"
  fi

  # T4-fast: Field cap from fixture.
  if python3 - "$_CAPPED_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]; c = s["counts"]; lims = d.get("limitations", [])
assert c["sampled"] == 2, f"expected sampled=2, got {c['sampled']}"
assert c["total_fields"] > c["sampled"], "total > sampled expected"
assert s.get("truncated") == True, f"expected truncated:true, got {s.get('truncated')!r}"
cap_lim = any("field" in l.lower() or "cap" in l.lower() for l in lims)
assert cap_lim, f"no field-cap limitation: {lims}"
print(f"OK: sampled=2 total={c['total_fields']} truncated=True limitation present")
PY
  then ok "T4-fast: field cap (fixture): sampled<total, truncated:true, limitation"
  else no "T4-fast: field cap (fixture)"
  fi

  # T13-fast: Isolation profile (CONTAINMENT guard) from fixture.
  # Anti-#128: preserved in fast lane — checks the isolation profile recorded in the
  # evidence JSON, proving the SUT configured network denial and no code execution.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert profile.get("static_only") == True, f"static_only not True: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
print(f"OK: isolation profile={profile}")
PY
  then ok "T13-fast: isolation (fixture): network-denial, static-only profile (CONTAINMENT)"
  else no "T13-fast: isolation (fixture)"
  fi

fi # fast | all

# ---------------------------------------------------------------------------
# UNIT TESTS — run in all lanes (pure Python; no tool spawn; always sub-second)
# ---------------------------------------------------------------------------

# T12: _toolchain_scope_guard unit tests (direct module import).
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location(
    "corroborate_kaitai", toolbelt / "corroborate_kaitai.py"
)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

for bad in ["/", "/home", "/home/linuxbrew", "/usr", "/etc"]:
    try:
        m._toolchain_scope_guard(Path(bad))
        print(f"FAIL: {bad!r} should be scope-rejected", file=sys.stderr); sys.exit(1)
    except m.KaitaiError:
        pass

with tempfile.TemporaryDirectory() as tmp:
    fake = Path(tmp) / "a" / "b" / "c"
    fake.mkdir(parents=True)
    try:
        m._toolchain_scope_guard(fake)
    except m.KaitaiError as exc:
        print(f"FAIL: {fake} should pass scope guard: {exc}", file=sys.stderr); sys.exit(1)
    try:
        m._jdk_home_guard(fake)
        print("FAIL: fake jdk should be rejected by markers", file=sys.stderr); sys.exit(1)
    except m.KaitaiError:
        pass

print("OK: scope guard rejects bad paths; fake jdk rejected by markers")
PY
then ok "T12: _toolchain_scope_guard: rejects bad paths; markers reject fake jdk"
else no "T12: _toolchain_scope_guard unit tests"
fi

# T17: run_truncation OR-wiring + scope-guard composition.
# Also validates: analyzer-exit is NOT a truncation event (fast-lane teeth target).
if python3 - "$TOOLBELT" <<'PY'
import sys, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location(
    "corroborate_kaitai", toolbelt / "corroborate_kaitai.py"
)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# analyzer-exit:N must NOT set truncated — it is a complete failure, not a partial result.
lims, errs, trunc = m._build_limitations_and_errors(None, ["analyzer-exit:1"], None)
assert trunc == False, \
    f"analyzer-exit must NOT set truncated (not a cap event), got trunc={trunc}"

# timeout → truncated=True
lims, errs, trunc = m._build_limitations_and_errors(None, ["timeout"], None)
assert trunc == True, f"timeout must set truncated=True, got {trunc}"
assert any("timeout" in l for l in lims), f"timeout limitation missing: {lims}"

# output-cap → truncated=True
lims, errs, trunc = m._build_limitations_and_errors(None, ["output-cap"], None)
assert trunc == True, f"output-cap must set truncated=True, got {trunc}"

# scope-guard composition: _bind_jvm_toolchain must reject shallow brew root.
original = m._brew_root_for
m._brew_root_for = lambda p: Path("/home/fake_user")
try:
    m._bind_jvm_toolchain(
        ["bwrap", "--"],
        Path("/home/fake_user/bin/ksc"),
        Path("/usr/lib/jvm/openjdk"),
        Path("/tmp/rsdd/gen"),
    )
    print("FAIL: shallow brew root must raise KaitaiError", file=sys.stderr); sys.exit(1)
except m.KaitaiError:
    pass
finally:
    m._brew_root_for = original

print("OK: analyzer-exit does NOT set truncated; run-trunc wiring correct; scope-guard OK")
PY
then ok "T17: run_truncation OR-wiring (analyzer-exit!=truncated) + scope-guard composition"
else no "T17: run_truncation OR-wiring + scope-guard composition"
fi

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: mutation controls (fast-lane T17 analyzer-exit assertion bites) --"

  # teeth-1: make analyzer-exit set truncated=True in _build_limitations_and_errors.
  # Mutation: change "if run_trunc:" to also fire when analyzer-exit is in run_errors.
  # T17 asserts trunc==False for analyzer-exit; with the mutation trunc==True → RED.
  _MUT_DIR="$(mktemp -d)"
  _MUT_PY="$_MUT_DIR/corroborate_kaitai.py"

  if ! grep -qF 'if run_trunc:' "$TOOLBELT/corroborate_kaitai.py"; then
    no "teeth-1: mutation target 'if run_trunc:' not found in SUT (SUT changed?)"
  else
    sed 's/if run_trunc:/if run_trunc or any(e.startswith("analyzer-exit:") for e in run_errors):  # mutant/g' \
      "$TOOLBELT/corroborate_kaitai.py" > "$_MUT_PY"

    _teeth_rc=0
    python3 - "$_MUT_DIR" "$TOOLBELT" <<'PY' || _teeth_rc=$?
import sys, importlib.util
from pathlib import Path

mut_dir  = Path(sys.argv[1]).resolve()
toolbelt = Path(sys.argv[2]).resolve()

# Add real toolbelt so lib/ imports resolve; mutant inserts its own dir during exec.
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_kaitai_mut", mut_dir / "corroborate_kaitai.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Run T17 assertion against the mutant:
# analyzer-exit:1 should NOT set truncated; mutant makes it set truncated=True.
_, _, trunc = m._build_limitations_and_errors(None, ["analyzer-exit:1"], None)
if trunc is True:
    # Mutant made analyzer-exit set truncated=True — assertion fails → RED.
    print("T17: mutant made analyzer-exit set truncated=True — assertion BITES",
          file=sys.stderr)
    sys.exit(1)  # test goes RED = teeth confirmed
else:
    # Mutation had no effect; assertion would still pass → no teeth.
    print("T17: mutant did not change truncated for analyzer-exit — teeth missing",
          file=sys.stderr)
    sys.exit(0)
PY

    if [[ "$_teeth_rc" -ne 0 ]]; then
      ok "teeth-1: T17 goes RED with mutant analyzer-exit→truncated: assertion bites"
    else
      no "teeth-1: T17 stayed GREEN with mutant: assertion has no teeth"
    fi
  fi

  rm -rf "$_MUT_DIR"
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
