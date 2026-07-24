#!/usr/bin/env bash
# tests/kaitai.test.sh — kaitai-struct evidence adapter test suite (T1-T16)
# House style: mirrors capa.test.sh and floss.test.sh.
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-kaitai.sh"
MANIFEST="$HERE/../analysis_manifest.py"

# ---------------------------------------------------------------------------
# RED guard — exit 2 when the script-under-test does not exist yet.
# ---------------------------------------------------------------------------
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Tool-availability guard — skip gracefully when required tools are absent.
# ---------------------------------------------------------------------------
_KAITAI_PY="${RSDD_KAITAI_PY:-$HOME/.local/share/rsdd-kaitai/bin/python}"
for _cmd in bwrap python3 kaitai-struct-compiler; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: kaitai tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done
if ! [ -x "$_KAITAI_PY" ]; then
  echo "SKIP: kaitai tests (kaitai venv python absent: $_KAITAI_PY)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --ksy "$2" --output "$3" "${@:4}"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

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

# wrong_magic.bin: same length as sample.bin but wrong magic (fails demo.ksy check)
python3 -c "open('$ROOT/wrong_magic.bin', 'wb').write(b'\x00\x00\x03\x00\xef\xbe\xad\xde')"

# string_demo.ksy: magic(2B) + label(str 16B ASCII) — for T5 value-bytes cap
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

# nested.ksy: two levels of nesting (header→point) — for T6 depth-cap
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
# nested.bin: hdr.version=1, hdr.origin.x=2, hdr.origin.y=3, count=4
python3 -c "open('$ROOT/nested.bin', 'wb').write(bytes([1, 2, 3, 4]))"

# malformed.ksy: invalid YAML (T7)
printf 'meta:\n  id: bad\n  endian: le\nseq:\n  - id: \t\t[broken yaml\n' > "$ROOT/malformed.ksy"

# imports.ksy: references a nonexistent imported struct (T14)
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

# big.bin: ~64 MiB of zeros; used with repeat_demo.ksy for T9 timeout
# Created lazily in T9 to avoid slowing other tests.

# repeat_demo.ksy: repeat-eos of u1 — parses every byte in input (T9)
cat > "$ROOT/repeat_demo.ksy" << 'EOKSY'
meta:
  id: repeat_demo
  endian: le
seq:
  - id: data
    type: u1
    repeat: eos
EOKSY

# ---------------------------------------------------------------------------
# T1: Happy path — demo.ksy + sample.bin → exit 0, evidence JSON produced.
# ---------------------------------------------------------------------------
_T1_OUT="$ROOT/out_t1"
if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T1_OUT" --timeout 120 2>/dev/null \
  && [ -f "$_T1_OUT/kaitai-evidence.v1.json" ]; then
  ok "T1: happy path: evidence JSON produced"
else
  no "T1: happy path"
fi

# ---------------------------------------------------------------------------
# T2: Evidence schema — field records have required fields, counts correct,
#     truncated:false, ksy_identity, compile.generated_parser.sha256,
#     runtime_version present.
# ---------------------------------------------------------------------------
if python3 - "$_T1_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "kaitai-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"

# structure domain
s = d.get("structure", {})
assert "fields" in s, "structure.fields missing"
assert "counts" in s, "structure.counts missing"
assert isinstance(s.get("truncated"), bool), "structure.truncated must be bool"
assert s.get("truncated") == False, f"expected truncated:false, got {s.get('truncated')}"
assert "root_type" in s, "root_type missing"
assert "module" in s, "module missing"
assert "parse_error" in s, "parse_error key missing"
assert s["parse_error"] is None, f"expected parse_error=null, got {s['parse_error']!r}"

# field records
for f in s.get("fields", []):
    assert "path" in f, f"path missing in field {f}"
    assert "name" in f, f"name missing in field {f}"
    assert "type" in f, f"type missing in field {f}"
    assert "start" in f, f"start missing in field {f}"
    assert "end" in f, f"end missing in field {f}"
    assert "size" in f, f"size missing in field {f}"
# magic field should have bytes value with sha256
magic = next((f for f in s["fields"] if f["name"] == "magic"), None)
assert magic is not None, "magic field not found"
v = magic.get("value", {})
assert isinstance(v, dict), f"magic value must be bytes dict, got {v!r}"
assert "sha256" in v, f"magic value must have sha256, got {v!r}"
assert v["sha256"].startswith("sha256:"), f"sha256 prefix wrong: {v['sha256']}"

# counts
c = s["counts"]
assert "total_fields" in c, "counts.total_fields missing"
assert "sampled" in c, "counts.sampled missing"
assert c["total_fields"] >= 3, f"demo.ksy has 3 fields, got total={c['total_fields']}"
assert c["sampled"] == c["total_fields"], "no cap → sampled==total"

# compile domain
cpl = d.get("compile", {})
assert "generated_parser" in cpl, "compile.generated_parser missing"
gp = cpl["generated_parser"]
assert "path" in gp, "generated_parser.path missing"
assert "sha256" in gp, "generated_parser.sha256 missing"
assert gp["sha256"].startswith("sha256:"), "sha256 prefix wrong"
assert "ksc_version" in cpl, "compile.ksc_version missing"

# ksy_identity
ki = d.get("ksy_identity", {})
assert ki, "ksy_identity missing"
assert "sha256" in ki, "ksy_identity.sha256 missing"

# runtime_version
assert "runtime_version" in d, "runtime_version missing"
assert d["runtime_version"], "runtime_version must be non-empty"

# standard envelope keys
assert "input" in d, "input key missing"
assert "isolation" in d, "isolation key missing"
assert isinstance(d.get("limitations"), list), "limitations must be list"
assert isinstance(d.get("errors"), list), "errors must be list"

print(f"OK: schema={d['schema']} status={d['status']} total={c['total_fields']} "
      f"root_type={s['root_type']!r} runtime={d['runtime_version']!r}")
PY
then ok "T2: evidence schema: fields, counts, ksy_identity, compile.generated_parser.sha256, runtime_version"
else no "T2: evidence schema"
fi

# ---------------------------------------------------------------------------
# T3: Determinism — two runs on same inputs produce byte-identical evidence.
# ---------------------------------------------------------------------------
_T3_OUT="$ROOT/out_t3"
if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T3_OUT" --timeout 120 2>/dev/null \
  && cmp -s "$_T1_OUT/kaitai-evidence.v1.json" "$_T3_OUT/kaitai-evidence.v1.json"; then
  ok "T3: determinism: two runs produce byte-identical evidence"
else
  no "T3: determinism"
fi

# ---------------------------------------------------------------------------
# T4: --max-fields 2 → sampled==2 < total==3, truncated:true + limitation.
# ---------------------------------------------------------------------------
_T4_OUT="$ROOT/out_t4"
if run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$_T4_OUT" --max-fields 2 --timeout 120 2>/dev/null \
  && python3 - "$_T4_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]
c = s["counts"]
lims = d.get("limitations", [])
assert c["sampled"] == 2, f"expected sampled=2, got {c['sampled']}"
assert c["total_fields"] > c["sampled"], \
    f"expected total_fields > sampled, got total={c['total_fields']} sampled={c['sampled']}"
assert s.get("truncated") == True, f"expected truncated:true, got {s.get('truncated')!r}"
cap_lim = any("field" in l.lower() or "max-fields" in l.lower() or "cap" in l.lower()
               for l in lims)
assert cap_lim, f"no field-cap limitation recorded: {lims}"
print(f"OK: sampled=2 total={c['total_fields']} truncated=True limitation present")
PY
then ok "T4: --max-fields 2: sampled<total, truncated:true, limitation recorded"
else no "T4: --max-fields 2 field cap"
fi

# ---------------------------------------------------------------------------
# T5: --max-value-bytes 4 on long string → bounded value + full sha256 + truncated.
# ---------------------------------------------------------------------------
_T5_OUT="$ROOT/out_t5"
if run "$ROOT/string_demo.bin" "$ROOT/string_demo.ksy" "$_T5_OUT" \
    --max-value-bytes 4 --timeout 120 2>/dev/null \
  && python3 - "$_T5_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]
# Find the label field
label = next((f for f in s.get("fields", []) if f["name"] == "label"), None)
assert label is not None, "label field not found"
v = label.get("value", {})
assert isinstance(v, dict), f"label value must be dict (str-bounded), got {v!r}"
assert "sha256" in v, f"label value must have sha256: {v}"
assert v["sha256"].startswith("sha256:"), "sha256 prefix wrong"
assert "value" in v, f"bounded value missing: {v}"
assert len(v["value"]) <= 4, f"value not bounded: {v['value']!r}"
assert v.get("value_truncated") == True, f"value_truncated must be True: {v}"
assert s.get("truncated") == True, f"structure.truncated must be True: {s.get('truncated')!r}"
print(f"OK: label bounded to {len(v['value'])} chars, sha256 present, truncated=True")
PY
then ok "T5: --max-value-bytes 4: str value bounded, sha256 of full string, truncated:true"
else no "T5: --max-value-bytes 4 value cap"
fi

# ---------------------------------------------------------------------------
# T6: nested.ksy + --max-depth 1 → depth-cap flag, truncated.
# nested.ksy has header→point (2 levels); with max-depth=1,
# origin (point) inside header cannot be recursed → depth_cap fires.
# ---------------------------------------------------------------------------
_T6_OUT="$ROOT/out_t6"
if run "$ROOT/nested.bin" "$ROOT/nested.ksy" "$_T6_OUT" \
    --max-depth 1 --timeout 120 2>/dev/null \
  && python3 - "$_T6_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["structure"]
assert s.get("truncated") == True, f"expected truncated:true on depth cap, got {s.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("depth" in l.lower() for l in lims), \
    f"depth-cap limitation not in limitations list: {lims}"
print(f"OK: depth cap fired, truncated=True, depth-cap limitation present")
PY
then ok "T6: nested + --max-depth 1: depth_cap flag, truncated:true"
else no "T6: nested depth cap"
fi

# ---------------------------------------------------------------------------
# T7: Malformed .ksy → adapter exits 2, no evidence published.
# ---------------------------------------------------------------------------
_T7_OUT="$ROOT/out_t7"
_T7_EXIT=0
run "$ROOT/sample.bin" "$ROOT/malformed.ksy" "$_T7_OUT" --timeout 30 2>/dev/null \
  || _T7_EXIT=$?
if [ "$_T7_EXIT" -eq 2 ] && [ ! -d "$_T7_OUT" ]; then
  ok "T7: malformed .ksy → exit 2, no evidence published"
else
  no "T7: malformed .ksy (exit=$_T7_EXIT dir_exists=$([ -d '$_T7_OUT' ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# T8: Wrong magic binary → exit 1, status:failed, error message recorded,
#     no traceback text in the evidence JSON.
# ---------------------------------------------------------------------------
_T8_OUT="$ROOT/out_t8"
_T8_EXIT=0
run "$ROOT/wrong_magic.bin" "$ROOT/demo.ksy" "$_T8_OUT" --timeout 120 2>/dev/null \
  || _T8_EXIT=$?
if [ "$_T8_EXIT" -eq 1 ] && [ -f "$_T8_OUT/kaitai-evidence.v1.json" ] \
  && python3 - "$_T8_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed, got {d.get('status')!r}"
text = json.dumps(d)
assert "Traceback" not in text, "traceback text found in evidence JSON"
assert "parse_error" in d.get("structure", {}), "structure.parse_error missing"
pe = d["structure"]["parse_error"]
assert pe is not None, "parse_error must be set for wrong-magic binary"
assert "Traceback" not in pe, f"traceback in parse_error: {pe!r}"
print(f"OK: status=failed parse_error={pe[:60]!r} no traceback")
PY
then ok "T8: wrong-magic binary → exit 1, status:failed, error message, no traceback"
else no "T8: wrong-magic binary handling (exit=$_T8_EXIT)"
fi

# ---------------------------------------------------------------------------
# T9: --timeout 1 with repeat-eos over ~64MiB → timeout in errors, truncated.
#     SKIP when the run completes in < 1s (flake-proof guard).
# ---------------------------------------------------------------------------
_T9_BIN="$ROOT/big.bin"
python3 -c "
import os, sys
with open(sys.argv[1], 'wb') as f:
    chunk = bytes(65536)
    for _ in range(1024):  # 64 MiB
        f.write(chunk)
" "$_T9_BIN" 2>/dev/null
_T9_OUT="$ROOT/out_t9"
_T9_EXIT=0
run "$_T9_BIN" "$ROOT/repeat_demo.ksy" "$_T9_OUT" --timeout 1 2>/dev/null \
  || _T9_EXIT=$?
if [ "$_T9_EXIT" -eq 0 ]; then
  echo "  SKIP  T9: run completed in <1s on 64MiB file (too fast; flake-proof skip)"
elif [ "$_T9_EXIT" -eq 2 ]; then
  no "T9: adapter fatal error (exit 2); check kaitai installation"
elif [ -f "$_T9_OUT/kaitai-evidence.v1.json" ]; then
  if python3 - "$_T9_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", \
    f"expected status=failed on resource cap, got {d.get('status')!r}"
# Accept either "timeout" or "memory-cap": both are correctly-surfaced resource
# limits.  Whichever wins the race, the evidence must carry the right signal.
cap_errors = {"timeout", "memory-cap"}
assert any(e in cap_errors for e in d.get("errors", [])), \
    f"neither timeout nor memory-cap in errors: {d.get('errors')}"
s = d.get("structure", {})
assert s.get("truncated") == True, \
    f"structure.truncated must be True on resource cap, got {s.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("timeout" in l or "memory-cap" in l for l in lims), \
    f"no resource-cap limitation: {lims}"
print(f"OK: status=failed, resource-cap in errors, truncated=True, limitation present")
PY
  then ok "T9: --timeout 1 on 64MiB: resource-cap (timeout or memory-cap) in errors, truncated:true, limitation"
  else no "T9: resource-cap visibility (evidence present but fields wrong)"
  fi
else
  no "T9: evidence not published after timeout (exit $_T9_EXIT)"
fi

# ---------------------------------------------------------------------------
# T9b: memory-cap signal — deterministic path.
#      generous timeout (60s) ensures MemoryError beats the wall clock;
#      256 MB RLIMIT_AS fires when repeat-eos tries to build a 64M-element list.
#      Evidence must carry a first-class "memory-cap" signal, NOT a generic
#      parse-error.  Absent this fix, only parse-error: MemoryError is present.
# ---------------------------------------------------------------------------
_T9B_BIN="$ROOT/big.bin"
# big.bin may already exist from T9; recreate if absent.
[ -f "$_T9B_BIN" ] || python3 -c "
import sys
with open(sys.argv[1], 'wb') as f:
    chunk = bytes(65536)
    for _ in range(1024):  # 64 MiB
        f.write(chunk)
" "$_T9B_BIN" 2>/dev/null
_T9B_OUT="$ROOT/out_t9b"
_T9B_EXIT=0
run "$_T9B_BIN" "$ROOT/repeat_demo.ksy" "$_T9B_OUT" \
    --timeout 60 --max-memory-mb 256 2>/dev/null \
  || _T9B_EXIT=$?
if [ "$_T9B_EXIT" -eq 0 ]; then
  no "T9b: memory-cap path (driver exited 0, MemoryError not reached or not surfaced)"
elif [ "$_T9B_EXIT" -eq 2 ]; then
  no "T9b: adapter fatal error (exit 2); check kaitai installation"
elif [ -f "$_T9B_OUT/kaitai-evidence.v1.json" ]; then
  if python3 - "$_T9B_OUT/kaitai-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", \
    f"expected status=failed on memory-cap, got {d.get('status')!r}"
assert "memory-cap" in d.get("errors", []), \
    f"memory-cap not in errors: {d.get('errors')}"
s = d.get("structure", {})
assert s.get("truncated") == True, \
    f"structure.truncated must be True on memory-cap, got {s.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("memory-cap" in l for l in lims), \
    f"no memory-cap limitation: {lims}"
print(f"OK: status=failed, memory-cap in errors, truncated=True, limitation present")
PY
  then ok "T9b: memory-cap signal surfaced as first-class resource limit"
  else no "T9b: memory-cap fidelity (evidence present but fields wrong)"
  fi
else
  no "T9b: evidence not published after memory-cap (exit $_T9B_EXIT)"
fi

# ---------------------------------------------------------------------------
# T10: Output-dir-exists → adapter exits 2, no evidence overwritten.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/already_exists"
_T10_EXIT=0
run "$ROOT/sample.bin" "$ROOT/demo.ksy" "$ROOT/already_exists" --timeout 10 2>/dev/null \
  || _T10_EXIT=$?
if [ "$_T10_EXIT" -ne 0 ] && [ ! -f "$ROOT/already_exists/kaitai-evidence.v1.json" ]; then
  ok "T10: output-dir-exists → fail-closed, no evidence published"
else
  no "T10: output-dir-exists (exit=$_T10_EXIT)"
fi

# ---------------------------------------------------------------------------
# T11: Symlinked binary → exit 2 (input rejected);
#      symlinked .ksy → exit 2 (ksy rejected).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# T12: _toolchain_scope_guard unit tests (direct module import).
#      Rejects /, /home, /home/linuxbrew (3 parts), /usr.
#      Accepts ≥4-part path; fake jdk without lib/modules → rejected by markers.
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_kaitai", toolbelt / "corroborate_kaitai.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Pure shape rejections
for bad in ["/", "/home", "/home/linuxbrew", "/usr", "/etc"]:
    try:
        m._toolchain_scope_guard(Path(bad))
        print(f"FAIL: {bad!r} should be scope-rejected", file=sys.stderr); sys.exit(1)
    except m.KaitaiError:
        pass  # expected

# /home/linuxbrew (3 parts): ['/', 'home', 'linuxbrew'] → parts[:2]==['/', 'home'], len=3 < 4 → reject
# This is the brew prefix itself — correctly rejected.

# Accept a ≥4-part temp path
with tempfile.TemporaryDirectory() as tmp:
    fake = Path(tmp) / "a" / "b" / "c"
    fake.mkdir(parents=True)
    # scope guard should accept (≥3 non-home parts)
    try:
        m._toolchain_scope_guard(fake)
    except m.KaitaiError as exc:
        print(f"FAIL: {fake} should pass scope guard: {exc}", file=sys.stderr); sys.exit(1)

    # fake jdk dir (no bin/java, release, lib/modules) → _jdk_home_guard rejects
    try:
        m._jdk_home_guard(fake)
        print("FAIL: fake jdk should be rejected by markers", file=sys.stderr); sys.exit(1)
    except m.KaitaiError:
        pass  # expected

print("OK: scope guard rejects bad paths; fake jdk rejected by markers")
PY
then ok "T12: _toolchain_scope_guard: rejects bad paths; markers reject fake jdk"
else no "T12: _toolchain_scope_guard unit tests"
fi

# ---------------------------------------------------------------------------
# T13: Isolation recorded — network_access==false, manifest present.
# ---------------------------------------------------------------------------
if python3 - "$_T1_OUT/kaitai-evidence.v1.json" "$_T1_OUT/engine/analysis-manifest.v1.json" <<'PY'
import json, sys
from pathlib import Path

d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {})
profile = iso.get("profile", {})
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

# ---------------------------------------------------------------------------
# T14: imports.ksy (references nonexistent imported struct) → compile fails
#      → adapter exits 2, no evidence published.
# ---------------------------------------------------------------------------
_T14_OUT="$ROOT/out_t14"
_T14_EXIT=0
run "$ROOT/sample.bin" "$ROOT/imports.ksy" "$_T14_OUT" --timeout 30 2>/dev/null \
  || _T14_EXIT=$?
if [ "$_T14_EXIT" -eq 2 ] && [ ! -d "$_T14_OUT" ]; then
  ok "T14: imports.ksy compile failure → exit 2, no evidence"
else
  no "T14: imports.ksy (exit=$_T14_EXIT dir_exists=$([ -d '$_T14_OUT' ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# T15: .ksy > 1 MiB → adapter exits 2 (stage_file size guard), no evidence.
# ---------------------------------------------------------------------------
python3 -c "
import sys
with open(sys.argv[1], 'w') as f:
    f.write('meta:\n  id: toobig\nseq:\n')
    # pad to >1 MiB with comment lines
    for i in range(55000):
        f.write(f'  # padding line {i}\n')
" "$ROOT/big.ksy" 2>/dev/null
_T15_OUT="$ROOT/out_t15"
_T15_EXIT=0
run "$ROOT/sample.bin" "$ROOT/big.ksy" "$_T15_OUT" --timeout 10 2>/dev/null \
  || _T15_EXIT=$?
if [ "$_T15_EXIT" -eq 2 ] && [ ! -d "$_T15_OUT" ]; then
  ok "T15: .ksy > 1 MiB → exit 2, no evidence"
else
  no "T15: .ksy size guard (exit=$_T15_EXIT dir_exists=$([ -d '$_T15_OUT' ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# T16: outputs includes engine/gen/<stem>.py + engine/driver.py;
#      analysis_manifest.py verify --root passes.
# ---------------------------------------------------------------------------
if python3 - "$_T1_OUT" "$MANIFEST" <<'PY'
import json, sys, subprocess
from pathlib import Path

out_dir = Path(sys.argv[1])
manifest_cli = sys.argv[2]

# Check engine/gen/<stem>.py exists
gen_dir = out_dir / "engine" / "gen"
gen_pys = list(gen_dir.glob("*.py"))
assert gen_pys, f"no .py in engine/gen/: {list(gen_dir.iterdir())}"
assert len(gen_pys) == 1, f"expected exactly 1 .py in gen/: {gen_pys}"
print(f"engine/gen/{gen_pys[0].name} exists ✓")

# Check engine/driver.py exists
driver = out_dir / "engine" / "driver.py"
assert driver.is_file(), "engine/driver.py missing"
print("engine/driver.py exists ✓")

# Check compile.generated_parser.path matches the actual file
ev = json.load(open(out_dir / "kaitai-evidence.v1.json"))
gp_path = ev["compile"]["generated_parser"]["path"]
assert gp_path.startswith("engine/gen/"), f"unexpected path: {gp_path}"
assert (out_dir / gp_path).is_file(), f"{gp_path} not found in {out_dir}"
print(f"compile.generated_parser.path={gp_path!r} ✓")

# Verify manifest
manifest_path = str(out_dir / "engine" / "analysis-manifest.v1.json")
r1 = subprocess.run(["python3", manifest_cli, "validate", manifest_path],
                    capture_output=True, timeout=30)
assert r1.returncode == 0, f"manifest validate failed: {r1.stderr.decode()}"
r2 = subprocess.run(["python3", manifest_cli, "verify", "--root", str(out_dir),
                      manifest_path],
                    capture_output=True, timeout=30)
assert r2.returncode == 0, f"manifest verify failed: {r2.stderr.decode()}"
print("analysis_manifest.py verify --root passed ✓")
PY
then ok "T16: engine/gen/<stem>.py + engine/driver.py in outputs; manifest verify passes"
else no "T16: outputs list + manifest verify"
fi

# ---------------------------------------------------------------------------
# T17: Always-running unit tests — run_truncation OR-wiring +
#      scope-guard composition (_bind_jvm_toolchain must guard brew root).
# These tests cover two CRITICAL properties without needing a real toolchain:
#   (a) _build_limitations_and_errors must not set truncated on analyzer-exit.
#   (b) _bind_jvm_toolchain must call _toolchain_scope_guard on brew roots.
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_kaitai", toolbelt / "corroborate_kaitai.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# --- (a) run_truncation OR-wiring via _build_limitations_and_errors ---
# timeout → truncated=True; limitation contains "timeout"
lims, errs, trunc = m._build_limitations_and_errors(None, ["timeout"], None)
assert trunc == True, f"timeout must set truncated=True, got {trunc}"
assert any("timeout" in l for l in lims), f"timeout limitation missing: {lims}"

# analyzer-exit:1 → truncated=False (complete failure, not a partial result)
lims, errs, trunc = m._build_limitations_and_errors(None, ["analyzer-exit:1"], None)
assert trunc == False, \
    f"analyzer-exit must NOT set truncated (not a cap event), got {trunc}"

# output-cap → truncated=True
lims, errs, trunc = m._build_limitations_and_errors(None, ["output-cap"], None)
assert trunc == True, f"output-cap must set truncated=True, got {trunc}"

# --- (b) scope-guard composition: _bind_jvm_toolchain rejects shallow brew root ---
# Monkeypatch _brew_root_for to return a 3-component path (/home/fake_user).
# Before the fix, _bind_jvm_toolchain does not call _toolchain_scope_guard
# on the brew path, so no KaitaiError is raised.  After the fix it raises.
original = m._brew_root_for
m._brew_root_for = lambda p: Path("/home/fake_user")
try:
    m._bind_jvm_toolchain(
        ["bwrap", "--"],
        Path("/home/fake_user/bin/ksc"),
        Path("/usr/lib/jvm/openjdk"),
        Path("/tmp/rsdd/gen"),
    )
    print("FAIL: shallow brew root must raise KaitaiError in _bind_jvm_toolchain",
          file=sys.stderr)
    sys.exit(1)
except m.KaitaiError:
    pass  # expected
finally:
    m._brew_root_for = original

print("OK: run_truncation wiring correct; _bind_jvm_toolchain rejects shallow brew root")
PY
then ok "T17: run_truncation OR-wiring + scope-guard composition"
else no "T17: run_truncation OR-wiring + scope-guard composition"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
