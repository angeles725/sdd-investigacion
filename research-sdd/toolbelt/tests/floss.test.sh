#!/usr/bin/env bash
# tests/floss.test.sh — floss evidence adapter test suite (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based schema/cap/isolation assertions + unit tests.
#                    No floss spawn.  Always emits "== N passed · N failed ==".
#   slow           — real floss run; requires floss + bwrap + python3.
#   all            — both fast and slow paths.
#
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT="$TOOLBELT/corroborate-floss.sh"
MANIFEST="$TOOLBELT/analysis_manifest.py"

# Source lane helper (idempotent; aborts on invalid RSDD_TEST_LANE value).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the script-under-test does not exist yet.
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }

# Determine active lane (aborts on invalid value per §7 anti-silent-zero).
_lane="$(rsdd_lane)"

# Fixture paths resolved here; existence is checked in the fast section.
_HAPPY_FIX="$(rsdd_lane_fixture floss happy)"
_CAPPED_FIX="$(rsdd_lane_fixture floss capped)"
_LENCAP_FIX="$(rsdd_lane_fixture floss len_capped)"

# ---------------------------------------------------------------------------
# SLOW LANE — real floss run (tool required)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  # Tool-availability guard — informational skip for slow lane only.
  _slow_skip=0
  for _cmd in floss bwrap python3; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done

  if [[ "$_slow_skip" -eq 0 ]]; then
    _SLOW_ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$_SLOW_ROOT"' EXIT

    # tiny_pe.exe: minimal PE32 with known static strings.
    python3 - "$_SLOW_ROOT/tiny_pe.exe" <<'PY'
import struct, sys

def pe32_with_strings(strings_list):
    dos = bytearray(64)
    dos[0:2] = b'MZ'
    struct.pack_into('<I', dos, 0x3C, 64)
    coff = struct.pack('=HHIIIHH', 0x014c, 1, 0, 0, 0, 0xe0, 0x0102)
    part1 = b'\x0b\x01\x01\x00' + struct.pack('=IIIIII', 0, 0x200, 0, 0x1000, 0x1000, 0x2000)
    part2 = struct.pack('=III', 0x400000, 0x1000, 0x200)
    part3 = struct.pack('=HHHHHH', 4, 0, 0, 0, 4, 0)
    part4 = struct.pack('=IIIIHH', 0, 0x3000, 0x200, 0, 3, 0)
    part5 = struct.pack('=IIIIII', 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    opt = part1 + part2 + part3 + part4 + part5 + bytes(128)
    sec = struct.pack('=8sIIIIIIHHI', b'.rdata\x00\x00',
                      0x200, 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x40000040)
    hdr_raw = bytes(dos) + b'PE\x00\x00' + coff + opt + sec
    hdr = hdr_raw + bytes(0x200 - len(hdr_raw))
    sd = b''.join(s.encode() + b'\x00' for s in strings_list)
    pad = 0x200 - (len(sd) % 0x200)
    if pad < 0x200:
        sd += bytes(pad)
    return hdr + sd

strings = ['StaticAlphaString', 'StaticBetaString', 'StaticGammaString',
           'ObfuscatedTokenXYZ', 'SecretKeyValue123']
with open(sys.argv[1], 'wb') as f:
    f.write(pe32_with_strings(strings))
PY

    # empty.bin: 256 null bytes — floss exits 0 with no JSON output → empty inventory.
    python3 -c "open('$_SLOW_ROOT/empty.bin', 'wb').write(bytes(256))"

    # T1: Happy path.
    if run "$_SLOW_ROOT/tiny_pe.exe" "$_SLOW_ROOT/out_a" 2>/dev/null \
      && [ -f "$_SLOW_ROOT/out_a/floss-evidence.v1.json" ]; then
      ok "T1: happy path: evidence JSON produced"
    else
      no "T1: happy path"
    fi

    # T2: Evidence schema.
    if python3 - "$_SLOW_ROOT/out_a/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "floss-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "strings" in d, "strings domain key missing"
s = d["strings"]
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    assert cat in s, f"category {cat!r} missing"
    c = s[cat]
    assert "count" in c and "sampled" in c, f"count/sampled missing in {cat}"
    assert isinstance(c.get("truncated"), bool), f"truncated must be bool in {cat}"
    for e in c.get("strings", []):
        assert "sha256" in e and e["sha256"].startswith("sha256:"), f"bad sha256: {e}"
        assert "value" in e and "offset" in e, f"value/offset missing: {e}"
assert "total_count" in s and "total_sampled" in s, "total counts missing"
assert isinstance(s.get("truncated"), bool), "top-level truncated must be bool"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
assert d["isolation"].get("launcher", {}).get("path"), "launcher.path missing"
print(f"OK: schema={d['schema']} status={d['status']} total_count={s['total_count']}")
PY
    then ok "T2: evidence schema: required fields, categories, sha256 digests"
    else no "T2: evidence schema"
    fi

    # T3: Determinism.
    if run "$_SLOW_ROOT/tiny_pe.exe" "$_SLOW_ROOT/out_b" 2>/dev/null \
      && cmp -s "$_SLOW_ROOT/out_a/floss-evidence.v1.json" \
               "$_SLOW_ROOT/out_b/floss-evidence.v1.json"; then
      ok "T3: determinism: two runs produce byte-identical evidence"
    else
      no "T3: determinism"
    fi

    # T4: Analysis manifest.
    if python3 "$MANIFEST" validate "$_SLOW_ROOT/out_a/engine/analysis-manifest.v1.json" \
        >/dev/null 2>&1 \
      && python3 "$MANIFEST" verify --root "$_SLOW_ROOT/out_a" \
          "$_SLOW_ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
      ok "T4: analysis manifest validates and verifies"
    else no "T4: analysis manifest"; fi

    # T5: String cap.
    if run "$_SLOW_ROOT/tiny_pe.exe" "$_SLOW_ROOT/out_cap" --max-strings 2 2>/dev/null \
      && python3 - "$_SLOW_ROOT/out_cap/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]; lims = d.get("limitations", [])
assert s["total_sampled"] <= 2, f"string cap not enforced: total_sampled={s['total_sampled']}"
assert s["truncated"] == True, f"truncated must be True, got {s['truncated']!r}"
assert any("string cap" in l for l in lims), f"no string-cap limitation: {lims}"
print(f"OK: total_sampled={s['total_sampled']}, truncated=True, cap limitation present")
PY
    then ok "T5: string cap: total_sampled bounded, truncated=True, limitation recorded"
    else no "T5: string cap"
    fi

    # T6: Per-string length cap.
    if run "$_SLOW_ROOT/tiny_pe.exe" "$_SLOW_ROOT/out_len" --max-string-len 5 2>/dev/null \
      && python3 - "$_SLOW_ROOT/out_len/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]; lims = d.get("limitations", [])
all_entries = []
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    all_entries += s.get(cat, {}).get("strings", [])
for e in all_entries:
    assert len(e["value"]) <= 5, f"string exceeds max-string-len=5: {e['value']!r}"
assert any("string-length cap" in l for l in lims), f"no length-cap limitation: {lims}"
assert s["truncated"] == True, f"truncated must be True when length cap fires"
print(f"OK: {len(all_entries)} entries all <= 5 chars, length-cap limitation, truncated=True")
PY
    then ok "T6: per-string length cap: values truncated, limitation recorded"
    else no "T6: per-string length cap"
    fi

    # T7: Empty/benign input — status=complete with empty inventory.
    if run "$_SLOW_ROOT/empty.bin" "$_SLOW_ROOT/out_empty" 2>/dev/null \
      && python3 - "$_SLOW_ROOT/out_empty/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "floss-evidence.v1"
assert d.get("status") == "complete", f"expected status=complete, got {d.get('status')!r}"
s = d["strings"]
assert s["total_count"] == 0 and s["total_sampled"] == 0, "expected 0 counts"
assert s["truncated"] == False, "truncated must be False for empty inventory"
print(f"OK: status=complete, total_count=0, truncated=False")
PY
    then ok "T7: empty input: status=complete, empty inventory"
    else no "T7: empty input"
    fi

    # T8: Output-dir-exists.
    mkdir -p "$_SLOW_ROOT/already_exists"
    if ! run "$_SLOW_ROOT/tiny_pe.exe" "$_SLOW_ROOT/already_exists" 2>/dev/null \
      && [ ! -f "$_SLOW_ROOT/already_exists/floss-evidence.v1.json" ]; then
      ok "T8: output-dir-exists rejected fail-closed"
    else no "T8: output-dir-exists"; fi

    # T10: Isolation profile (CONTAINMENT).
    if python3 - "$_SLOW_ROOT/out_a/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
s = d.get("strings", {})
assert s.get("floss_version"), "floss_version must be non-empty"
print(f"OK: isolation profile={profile}, floss_version={s['floss_version']!r}")
PY
    then ok "T10: isolation: network-denial profile, launcher identity, floss_version"
    else no "T10: isolation profile"
    fi

    # T12: Timeout visibility (flake-proof: skip when floss finishes in <1s).
    _T12_OUT="$_SLOW_ROOT/out_timeout_floss"; _T12_EXIT=0
    run "$_SLOW_ROOT/tiny_pe.exe" "$_T12_OUT" --timeout 1 2>/dev/null || _T12_EXIT=$?
    if [ "$_T12_EXIT" -eq 0 ]; then
      echo "  SKIP  T12: floss finished in <1s on tiny_pe.exe (too fast; flake-proof skip)"
    elif [ "$_T12_EXIT" -eq 2 ]; then
      no "T12: adapter fatal error (exit 2); check floss installation"
    elif [ -f "$_T12_OUT/floss-evidence.v1.json" ]; then
      if python3 - "$_T12_OUT/floss-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed on timeout, got {d.get('status')!r}"
assert "timeout" in d.get("errors", []), f"timeout not in errors: {d.get('errors')}"
s = d.get("strings", {})
assert s.get("truncated") == True, f"strings.truncated must be True on timeout"
assert any("timeout" in l for l in d.get("limitations", [])), "no timeout limitation"
print(f"OK: status=failed, timeout in errors, strings.truncated=True, limitation present")
PY
      then ok "T12: --timeout 1: status=failed, strings.truncated=True, timeout limitation"
      else no "T12: timeout visibility"
      fi
    else
      no "T12: evidence not published after timeout (exit $_T12_EXIT)"
    fi
  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based assertions (no tool spawn; sub-second)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: fixtures must exist before asserting against them.
  for _fix in "$_HAPPY_FIX" "$_CAPPED_FIX" "$_LENCAP_FIX"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite floss" >&2
      exit 1
    fi
  done

  # T2-fast: Evidence schema from fixture.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "floss-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "strings" in d, "strings domain key missing"
s = d["strings"]
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    assert cat in s, f"category {cat!r} missing"
    c = s[cat]
    assert "count" in c and "sampled" in c, f"count/sampled missing in {cat}"
    assert isinstance(c.get("truncated"), bool), f"truncated must be bool in {cat}"
    for e in c.get("strings", []):
        assert "sha256" in e and e["sha256"].startswith("sha256:"), f"bad sha256: {e}"
        assert "value" in e and "offset" in e, f"value/offset missing: {e}"
assert "total_count" in s and "total_sampled" in s, "total counts missing"
assert isinstance(s.get("truncated"), bool), "top-level truncated must be bool"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
assert d["isolation"].get("launcher", {}).get("path"), "launcher.path missing"
print(f"OK: schema={d['schema']} status={d['status']} total_count={s['total_count']}")
PY
  then ok "T2-fast: evidence schema (fixture): required fields, categories, sha256"
  else no "T2-fast: evidence schema (fixture)"
  fi

  # T5-fast: String cap from fixture.
  if python3 - "$_CAPPED_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]; lims = d.get("limitations", [])
assert s["total_sampled"] <= 2, f"string cap not enforced: total_sampled={s['total_sampled']}"
assert s["truncated"] == True, f"truncated must be True, got {s['truncated']!r}"
assert any("string cap" in l for l in lims), f"no string-cap limitation: {lims}"
print(f"OK: total_sampled={s['total_sampled']}, truncated=True, cap limitation present")
PY
  then ok "T5-fast: string cap (fixture): bounded, truncated=True, limitation"
  else no "T5-fast: string cap (fixture)"
  fi

  # T6-fast: Per-string length cap from fixture.
  if python3 - "$_LENCAP_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]; lims = d.get("limitations", [])
all_entries = []
for cat in ("static_strings", "stack_strings", "tight_strings", "decoded_strings"):
    all_entries += s.get(cat, {}).get("strings", [])
for e in all_entries:
    assert len(e["value"]) <= 5, f"string exceeds max-string-len=5: {e['value']!r}"
assert any("string-length cap" in l for l in lims), f"no length-cap limitation: {lims}"
assert s["truncated"] == True, f"truncated must be True when length cap fires"
print(f"OK: {len(all_entries)} entries all <= 5 chars, length-cap limitation, truncated=True")
PY
  then ok "T6-fast: per-string length cap (fixture): values capped, limitation"
  else no "T6-fast: per-string length cap (fixture)"
  fi

  # T10-fast: Isolation profile (CONTAINMENT guard) from fixture.
  # Anti-#128: preserved in fast lane — checks the isolation profile recorded in the
  # evidence JSON, proving the SUT configured network denial and no code execution.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
s = d.get("strings", {})
assert s.get("floss_version"), "floss_version must be non-empty"
print(f"OK: isolation profile={profile}, floss_version={s['floss_version']!r}")
PY
  then ok "T10-fast: isolation (fixture): network-denial, no-exec profile (CONTAINMENT)"
  else no "T10-fast: isolation (fixture)"
  fi

fi # fast | all

# ---------------------------------------------------------------------------
# UNIT TESTS — run in all lanes (pure Python; no tool spawn; always sub-second)
# ---------------------------------------------------------------------------

# T9: O_NOFOLLOW — symlink at floss stdout path raises FlossError.
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_floss", toolbelt / "corroborate_floss.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    real = Path(tmp) / "real.txt"; real.write_bytes(b'{}')
    link = Path(tmp) / "stdout.txt"; link.symlink_to(real)
    try:
        m._read_stdout_json(link)
        print("FAIL: expected FlossError for symlink", file=sys.stderr); sys.exit(1)
    except m.FlossError:
        print("OK: FlossError raised for symlink at stdout path")
PY
then ok "T9: O_NOFOLLOW: symlink at floss stdout path raises FlossError"
else no "T9: O_NOFOLLOW symlink rejection"
fi

# T11: _read_stdout_json — malformed → (None, err_str); empty → (None, None).
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_floss", toolbelt / "corroborate_floss.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / "malformed.txt"; p.write_bytes(b'not json at all {{{{')
    val, err = m._read_stdout_json(p)
    assert val is None and isinstance(err, str) and err, f"malformed: expected (None,err)"
    e = Path(tmp) / "empty.txt"; e.write_bytes(b'')
    val2, err2 = m._read_stdout_json(e)
    assert val2 is None and err2 is None, f"empty: expected (None,None), got {(val2,err2)!r}"
    print("OK: _read_stdout_json returns (None,err) malformed; (None,None) empty")
PY
then ok "T11: _read_stdout_json: (None,err_str) malformed; (None,None) empty"
else no "T11: _read_stdout_json tuple return type"
fi

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: mutation controls (fast-lane length-cap assertion bites) --"

  # teeth-1: weaken string length cap in corroborate_floss.py.
  # Mutation: raw_val[:max_string_len] → raw_val[:max_string_len+99]
  # T6-fast (length-cap fixture) still passes (fixture values are already <=5).
  # Instead, we prove teeth via a direct unit test that calls _build_inventory
  # with strings LONGER than max_string_len and asserts they are capped to max.
  # With the mutation the cap fires at max+99 instead of max → assertion fails → RED.
  _MUT_DIR="$(mktemp -d)"
  _MUT_PY="$_MUT_DIR/corroborate_floss.py"

  # Verify mutation target exists before applying.
  if ! grep -qF 'raw_val = raw_val[:max_string_len]' "$TOOLBELT/corroborate_floss.py"; then
    no "teeth-1: mutation target not found in SUT (SUT changed?); cannot prove teeth"
  else
    sed 's|raw_val = raw_val\[:max_string_len\]|raw_val = raw_val[:max_string_len+99]  # mutant|g' \
      "$TOOLBELT/corroborate_floss.py" > "$_MUT_PY"

    _teeth_rc=0
    # Pass both mutant dir and real toolbelt so lib/ imports resolve correctly.
    python3 - "$_MUT_DIR" "$TOOLBELT" <<'PY' || _teeth_rc=$?
import sys, importlib.util
from pathlib import Path

mut_dir  = Path(sys.argv[1]).resolve()
toolbelt = Path(sys.argv[2]).resolve()

# Add real toolbelt so lib/ imports resolve; mutant inserts its own dir during exec.
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_floss_mut", mut_dir / "corroborate_floss.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Build a synthetic floss JSON with strings longer than max_string_len=5.
# _build_inventory should cap them at 5 chars; the mutant caps at 5+99=104.
long_str = "A" * 20  # 20 chars, well above max_string_len=5
floss_json = {
    "strings": {
        "static_strings": [{"string": long_str, "offset": 0, "encoding": "ASCII"}],
        "stack_strings":  [],
        "tight_strings":  [],
        "decoded_strings": [],
    }
}
inv, _ = m._build_inventory(floss_json, max_strings=100, max_string_len=5)
sampled = inv.get("static_strings", {}).get("strings", [])
if not sampled:
    print("FAIL: no sampled strings in inventory", file=sys.stderr)
    sys.exit(0)  # unexpected: no strings → cannot prove length cap

actual_len = len(sampled[0]["value"])
if actual_len > 5:
    # Mutant did NOT cap at 5: string is longer than expected.
    # The assertion `len(e["value"]) <= 5` in T6-fast would FAIL → teeth confirmed.
    print(f"T6: mutant produced string of len={actual_len} (> max_string_len=5) — assertion BITES",
          file=sys.stderr)
    sys.exit(1)  # test goes RED = teeth confirmed
else:
    # Mutant still capped at 5: assertion would still pass → no teeth.
    print(f"T6: string still capped at len={actual_len} despite mutation — teeth missing",
          file=sys.stderr)
    sys.exit(0)
PY

    if [[ "$_teeth_rc" -ne 0 ]]; then
      ok "teeth-1: T6 unit-test goes RED with mutant length cap: assertion bites"
    else
      no "teeth-1: T6 unit-test stayed GREEN with mutant: assertion has no teeth"
    fi
  fi

  rm -rf "$_MUT_DIR"
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
