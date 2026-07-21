#!/usr/bin/env bash
# tests/floss.test.sh — floss evidence adapter test suite
# House style: mirrors unblob.test.sh and corroborate-pcap.test.sh.
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-floss.sh"
MANIFEST="$HERE/../analysis_manifest.py"

# RED guard — exit 2 when the script-under-test does not exist yet.
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in floss bwrap python3; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: floss tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# tiny_pe.exe: minimal PE32 with known static strings.
# Used for happy-path, determinism, string-cap, and length-cap tests.
# Generated with inline Python to avoid build toolchain dependencies.
python3 - "$ROOT/tiny_pe.exe" <<'PY'
import struct, sys

def pe32_with_strings(strings_list):
    """Minimal PE32 binary with the given strings in the .rdata section."""
    dos = bytearray(64)
    dos[0:2] = b'MZ'
    struct.pack_into('<I', dos, 0x3C, 64)

    coff = struct.pack('=HHIIIHH', 0x014c, 1, 0, 0, 0, 0xe0, 0x0102)

    # Optional header PE32 (224 bytes):
    # magic(2) + linker(1+1) + SizeCode+InitData+UninitData+EntryPoint+BaseCode+BaseData(6×4)
    part1 = b'\x0b\x01\x01\x00' + struct.pack('=IIIIII', 0, 0x200, 0, 0x1000, 0x1000, 0x2000)
    part2 = struct.pack('=III', 0x400000, 0x1000, 0x200)
    part3 = struct.pack('=HHHHHH', 4, 0, 0, 0, 4, 0)
    part4 = struct.pack('=IIIIHH', 0, 0x3000, 0x200, 0, 3, 0)
    part5 = struct.pack('=IIIIII', 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    opt = part1 + part2 + part3 + part4 + part5 + bytes(128)  # 128 = 16 data dirs

    # Single .rdata section
    sec = struct.pack('=8sIIIIIIHHI',
        b'.rdata\x00\x00', 0x200, 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x40000040)

    hdr_raw = bytes(dos) + b'PE\x00\x00' + coff + opt + sec
    hdr = hdr_raw + bytes(0x200 - len(hdr_raw))

    sd = b''.join(s.encode() + b'\x00' for s in strings_list)
    pad = 0x200 - (len(sd) % 0x200)
    if pad < 0x200:
        sd += bytes(pad)
    return hdr + sd

strings = [
    'StaticAlphaString',
    'StaticBetaString',
    'StaticGammaString',
    'ObfuscatedTokenXYZ',
    'SecretKeyValue123',
]
with open(sys.argv[1], 'wb') as f:
    f.write(pe32_with_strings(strings))
print(f"created {sys.argv[1]}")
PY

# empty.bin: 256 null bytes — floss exits 0 with no JSON output → empty inventory.
python3 -c "open('$ROOT/empty.bin', 'wb').write(bytes(256))"

# ---------------------------------------------------------------------------
# T1: Happy path — floss runs on tiny_pe.exe and evidence JSON is produced.
# ---------------------------------------------------------------------------
if run "$ROOT/tiny_pe.exe" "$ROOT/out_a" 2>/dev/null \
  && [ -f "$ROOT/out_a/floss-evidence.v1.json" ]; then
  ok "happy path: evidence JSON produced"
else
  no "happy path"
fi

# ---------------------------------------------------------------------------
# T2: Evidence schema — required fields, categories, digests, envelope keys.
# ---------------------------------------------------------------------------
if python3 - "$ROOT/out_a/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "floss-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "strings" in d, "strings domain key missing"
s = d["strings"]
# All four categories must be present with required sub-fields.
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    assert cat in s, f"category {cat!r} missing"
    c = s[cat]
    assert "count" in c, f"count missing in {cat}"
    assert "sampled" in c, f"sampled missing in {cat}"
    assert isinstance(c.get("truncated"), bool), f"truncated must be bool in {cat}"
    for e in c.get("strings", []):
        assert "sha256" in e and e["sha256"].startswith("sha256:"), f"bad sha256: {e}"
        assert "value" in e, f"value missing: {e}"
        assert "offset" in e, f"offset missing: {e}"
# Top-level inventory fields
assert "total_count" in s, "total_count missing"
assert "total_sampled" in s, "total_sampled missing"
assert isinstance(s.get("truncated"), bool), "top-level truncated must be bool"
# Standard envelope keys
assert "input" in d, "input key missing"
assert "isolation" in d, "isolation key missing"
assert "limitations" in d, "limitations key missing"
assert "errors" in d, "errors key missing"
# Launcher identity
launcher = d["isolation"].get("launcher", {})
assert launcher.get("path"), "launcher.path missing"
print(f"OK: schema={d['schema']} status={d['status']} total_count={s['total_count']}")
PY
then ok "evidence schema: required fields, categories, sha256 digests"
else no "evidence schema"
fi

# ---------------------------------------------------------------------------
# T3: Determinism — two runs on same input produce byte-identical evidence.
# ---------------------------------------------------------------------------
if run "$ROOT/tiny_pe.exe" "$ROOT/out_b" 2>/dev/null \
  && cmp -s "$ROOT/out_a/floss-evidence.v1.json" "$ROOT/out_b/floss-evidence.v1.json"; then
  ok "determinism: two runs on same fixture produce byte-identical evidence"
else
  no "determinism"
fi

# ---------------------------------------------------------------------------
# T4: Analysis manifest validates and verifies.
# ---------------------------------------------------------------------------
if python3 "$MANIFEST" validate "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
  && python3 "$MANIFEST" verify --root "$ROOT/out_a" "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
  ok "analysis manifest validates and verifies"
else
  no "analysis manifest"
fi

# ---------------------------------------------------------------------------
# T5: String cap — max-strings=2 fires; total_sampled bounded; truncated=true;
#     at least one limitation records the string cap.
# ---------------------------------------------------------------------------
if run "$ROOT/tiny_pe.exe" "$ROOT/out_cap" --max-strings 2 2>/dev/null \
  && python3 - "$ROOT/out_cap/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]
lims = d.get("limitations", [])
assert s["total_sampled"] <= 2, f"string cap not enforced: total_sampled={s['total_sampled']}"
assert s["truncated"] == True, f"truncated must be True when string cap fires, got {s['truncated']!r}"
cap_hit = any("string cap" in l for l in lims)
assert cap_hit, f"no string-cap limitation recorded: {lims}"
print(f"OK: total_sampled={s['total_sampled']}, truncated=True, cap limitation present")
PY
then ok "string cap: total_sampled bounded, truncated=True, limitation recorded"
else no "string cap"
fi

# ---------------------------------------------------------------------------
# T6: Per-string length cap — max-string-len=5; every sampled value <= 5 chars;
#     limitation records the length cap.
# ---------------------------------------------------------------------------
if run "$ROOT/tiny_pe.exe" "$ROOT/out_len" --max-string-len 5 2>/dev/null \
  && python3 - "$ROOT/out_len/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]
lims = d.get("limitations", [])
all_entries = []
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    all_entries += s.get(cat, {}).get("strings", [])
for e in all_entries:
    assert len(e["value"]) <= 5, f"string exceeds max-string-len=5: {e['value']!r}"
len_cap = any("string-length cap" in l for l in lims)
assert len_cap, f"no string-length cap limitation recorded: {lims}"
assert s["truncated"] == True, f"truncated must be True when length cap fires, got {s['truncated']!r}"
print(f"OK: {len(all_entries)} sampled entries all <= 5 chars, length-cap limitation present, truncated=True")
PY
then ok "per-string length cap: values truncated, limitation recorded"
else no "per-string length cap"
fi

# ---------------------------------------------------------------------------
# T7: Empty/benign input — floss exits 0 with no JSON output; adapter publishes
#     status=complete with empty inventory (NOT fail-closed with exit 2).
# ---------------------------------------------------------------------------
if run "$ROOT/empty.bin" "$ROOT/out_empty" 2>/dev/null \
  && python3 - "$ROOT/out_empty/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "floss-evidence.v1"
assert d.get("status") == "complete", (
    f"expected status=complete for empty input, got {d.get('status')!r}"
)
s = d["strings"]
assert s["total_count"] == 0, f"expected total_count=0, got {s['total_count']}"
assert s["total_sampled"] == 0, f"expected total_sampled=0, got {s['total_sampled']}"
assert s["truncated"] == False, "truncated must be False for empty inventory"
print(f"OK: status=complete, total_count=0, truncated=False")
PY
then ok "empty input: valid status=complete empty inventory (NOT fail-closed)"
else no "empty input: expected status=complete with empty inventory"
fi

# ---------------------------------------------------------------------------
# T8: Output-dir-exists — adapter fails closed; no evidence published.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/already_exists"
if ! run "$ROOT/tiny_pe.exe" "$ROOT/already_exists" 2>/dev/null \
  && [ ! -f "$ROOT/already_exists/floss-evidence.v1.json" ]; then
  ok "output-dir-exists rejected fail-closed; no evidence published"
else
  no "output-dir-exists"
fi

# ---------------------------------------------------------------------------
# T9: O_NOFOLLOW — symlink at floss stdout path raises FlossError.
# Unit-tests _read_stdout_json() directly: a symlink at stdout.txt must be
# rejected even if the symlink target is a valid regular file.
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_floss", toolbelt / "corroborate_floss.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as tmp:
    real = Path(tmp) / "real.txt"
    real.write_bytes(b'{}')
    link = Path(tmp) / "stdout.txt"
    link.symlink_to(real)
    try:
        m._read_stdout_json(link)
        print("FAIL: expected FlossError for symlink, got no exception", file=sys.stderr)
        sys.exit(1)
    except m.FlossError:
        print("OK: FlossError raised for symlink at stdout path")
PY
then ok "O_NOFOLLOW: symlink at floss stdout path raises FlossError"
else no "O_NOFOLLOW symlink rejection"
fi

# ---------------------------------------------------------------------------
# T10: Isolation profile — network_access=false, target_execution=false,
#      launcher identity and floss_version recorded.
# ---------------------------------------------------------------------------
if python3 - "$ROOT/out_a/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {})
profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
s = d.get("strings", {})
assert "floss_version" in s, "floss_version missing from strings domain"
assert s["floss_version"], "floss_version must be non-empty"
print(f"OK: isolation profile={profile}, floss_version={s['floss_version']!r}")
PY
then ok "isolation: network-denial profile, launcher identity, and floss_version recorded"
else no "isolation profile"
fi


# ---------------------------------------------------------------------------
# T11: _read_stdout_json — unit test for new tuple return type.
#      Non-empty malformed file → (None, error_str).
#      Empty file → (None, None).
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_floss", toolbelt / "corroborate_floss.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as tmp:
    malformed = Path(tmp) / "malformed.txt"
    malformed.write_bytes(b'not json at all {{{{')
    result = m._read_stdout_json(malformed)
    assert isinstance(result, tuple) and len(result) == 2, \
        f"expected 2-tuple, got {result!r}"
    val, err = result
    assert val is None, f"expected None for malformed JSON, got {val!r}"
    assert isinstance(err, str) and err, \
        f"expected non-empty error str for malformed JSON, got {err!r}"

    empty = Path(tmp) / "empty.txt"
    empty.write_bytes(b'')
    result2 = m._read_stdout_json(empty)
    assert isinstance(result2, tuple) and len(result2) == 2, \
        f"expected 2-tuple for empty, got {result2!r}"
    val2, err2 = result2
    assert val2 is None, f"expected None for empty file, got {val2!r}"
    assert err2 is None, f"expected None error for empty file, got {err2!r}"
    print("OK: _read_stdout_json returns (None, err) for malformed; (None, None) for empty")
PY
then ok "T11: _read_stdout_json returns (None,err_str) for malformed; (None,None) for empty"
else no "T11: _read_stdout_json tuple return type"
fi

# ---------------------------------------------------------------------------
# T12: Timeout visibility — --timeout 1 must set strings.truncated=True and
#      record a timeout limitation.  Skip gracefully when floss finishes in <1s
#      (flake-proof: tiny_pe.exe is simple enough to parse very quickly).
# ---------------------------------------------------------------------------
_T12_OUT="$ROOT/out_timeout_floss"
_T12_EXIT=0
run "$ROOT/tiny_pe.exe" "$_T12_OUT" --timeout 1 2>/dev/null || _T12_EXIT=$?
if [ "$_T12_EXIT" -eq 0 ]; then
  echo "  SKIP  T12: floss finished in <1s on tiny_pe.exe (too fast; flake-proof skip)"
elif [ "$_T12_EXIT" -eq 2 ]; then
  no "T12: adapter fatal error (exit 2); check floss installation"
elif [ -f "$_T12_OUT/floss-evidence.v1.json" ]; then
  if python3 - "$_T12_OUT/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", \
    f"expected status=failed on timeout, got {d.get('status')!r}"
assert "timeout" in d.get("errors", []), \
    f"timeout not in errors: {d.get('errors')}"
s = d.get("strings", {})
assert s.get("truncated") == True, \
    f"strings.truncated must be True on timeout, got {s.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("timeout" in l for l in lims), \
    f"no timeout limitation string: {lims}"
print(f"OK: status=failed, timeout in errors, strings.truncated=True, limitation present")
PY
  then ok "T12: --timeout 1 sets status=failed, strings.truncated=True, timeout limitation recorded"
  else no "T12: timeout visibility (schema mismatch; evidence present but fields wrong)"
  fi
else
  no "T12: evidence not published after timeout (exit $_T12_EXIT)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
