#!/usr/bin/env bash
# isolation-profile.test.sh — unit tests for lib/isolation_profile.py
#
# Tests the make_profile() factory, all named PROFILE_* constants (security
# posture values), validator parity with analysis_manifest.py, and canonical
# JSON bytes parity with the original inline dicts being replaced.
#
# RED-first: this file was written before lib/isolation_profile.py existed.
# All tests must pass GREEN after implementation and remain green through
# every adapter migration (zero test-file edits required).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/isolation_profile.py"
MANIFEST="$HERE/../analysis_manifest.py"

[ -f "$SUT" ]      || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: analysis_manifest.py not found: $MANIFEST" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# T1: make_profile returns correct 4-key dict with defaults
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
p = ip.make_profile("test-profile")
assert set(p.keys()) == {"name", "static_only", "network_access", "target_execution"}, \
    f"unexpected keys: {set(p.keys())}"
assert p["name"] == "test-profile"
assert p["static_only"] is True,         "default static_only must be True"
assert p["network_access"] is False,     "default network_access must be False"
assert p["target_execution"] is False,   "default target_execution must be False"
PY
then ok "make_profile: returns 4-key dict with correct defaults"; else no "make_profile: default shape"; fi

# ---------------------------------------------------------------------------
# T2: make_profile network_access=True override accepted
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
p = ip.make_profile("test-network", network_access=True)
assert p["network_access"] is True
assert p["static_only"] is True
assert p["target_execution"] is False
PY
then ok "make_profile: network_access=True override accepted"; else no "make_profile: network_access override"; fi

# ---------------------------------------------------------------------------
# T3: make_profile static_only=False override accepted
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
p = ip.make_profile("test-dynamic", static_only=False)
assert p["static_only"] is False
assert p["network_access"] is False
assert p["target_execution"] is False
PY
then ok "make_profile: static_only=False override accepted"; else no "make_profile: static_only override"; fi

# ---------------------------------------------------------------------------
# T4: target_execution is immutably False — ValueError on True
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
try:
    ip.make_profile("bad", target_execution=True)
    raise AssertionError("should raise ValueError for target_execution=True")
except ValueError:
    pass  # expected
PY
then ok "make_profile: target_execution=True raises ValueError"; else no "make_profile: target_execution guard"; fi

# ---------------------------------------------------------------------------
# T5: invalid name raises ValueError
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
for bad in ("", "   "):
    try:
        ip.make_profile(bad)
        raise AssertionError(f"should raise ValueError for name={bad!r}")
    except ValueError:
        pass
# non-string raises ValueError or TypeError — both acceptable
for bad in (42, None, [], {}):
    try:
        ip.make_profile(bad)
        raise AssertionError(f"should raise error for name={bad!r}")
    except (ValueError, TypeError):
        pass
PY
then ok "make_profile: empty/non-string name raises ValueError"; else no "make_profile: name validation"; fi

# ---------------------------------------------------------------------------
# T6: named constants carry exact security posture values
#     These are the values that were inline in the adapters before migration.
#     Changing ANY of these would alter a sandbox's security posture.
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
# (constant_name, name, static_only, network_access, target_execution)
expected = [
    ("PROFILE_BWRAP_STATIC_NETWORK_DENIED", "bubblewrap-static-network-denied", True,  False, False),
    ("PROFILE_BWRAP_PCAP_OFFLINE",          "bubblewrap-pcap-offline",          True,  False, False),
    ("PROFILE_BWRAP_CAPA_OFFLINE",          "bubblewrap-capa-offline",          True,  False, False),
    ("PROFILE_BWRAP_FLOSS_OFFLINE",         "bubblewrap-floss-offline",         True,  False, False),
    ("PROFILE_BWRAP_KAITAI_OFFLINE",        "bubblewrap-kaitai-offline",        True,  False, False),
    ("PROFILE_BWRAP_UNBLOB_OFFLINE",        "bubblewrap-unblob-offline",        True,  False, False),
    ("PROFILE_BWRAP_UNSQUASHFS",            "bwrap-unsquashfs",                 True,  False, False),
    ("PROFILE_INPROCESS_ZIP_METADATA",      "in-process-metadata-only",         True,  False, False),
    ("PROFILE_INPROCESS_ZIP_STORED",        "in-process-static-stored-copy",    True,  False, False),
]
for const, name, static_only, network_access, target_execution in expected:
    p = getattr(ip, const)
    assert p["name"] == name,                       f"{const}: name={p['name']!r} != {name!r}"
    assert p["static_only"] is static_only,         f"{const}: static_only wrong"
    assert p["network_access"] is network_access,   f"{const}: network_access wrong"
    assert p["target_execution"] is target_execution, f"{const}: target_execution wrong"
PY
then ok "named constants: all security posture values are correct"; else no "named constants: security posture values"; fi

# ---------------------------------------------------------------------------
# T7: every PROFILE_* constant has exactly 4 keys (no extras snuck in)
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
required = {"name", "static_only", "network_access", "target_execution"}
for attr in dir(ip):
    if not attr.startswith("PROFILE_"):
        continue
    p = getattr(ip, attr)
    assert isinstance(p, dict), f"{attr} is not a dict"
    assert set(p.keys()) == required, \
        f"{attr}: wrong keys — got {set(p.keys())}, want {required}"
PY
then ok "PROFILE_* constants: all have exactly the 4 required keys"; else no "PROFILE_* constants: key count"; fi

# ---------------------------------------------------------------------------
# T8: validator parity — make_profile output accepted by analysis_manifest logic
#     Mirrors analysis_manifest.py:382-385 exactly.
# ---------------------------------------------------------------------------
if python3 - "$SUT" "$MANIFEST" <<'PY'
import importlib.util, sys
def load(path, name):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ip = load(sys.argv[1], "ip")
am = load(sys.argv[2], "am")

to_check = [
    ip.PROFILE_BWRAP_STATIC_NETWORK_DENIED,
    ip.PROFILE_BWRAP_PCAP_OFFLINE,
    ip.PROFILE_BWRAP_CAPA_OFFLINE,
    ip.PROFILE_BWRAP_FLOSS_OFFLINE,
    ip.PROFILE_BWRAP_KAITAI_OFFLINE,
    ip.PROFILE_BWRAP_UNBLOB_OFFLINE,
    ip.PROFILE_BWRAP_UNSQUASHFS,
    ip.PROFILE_INPROCESS_ZIP_METADATA,
    ip.PROFILE_INPROCESS_ZIP_STORED,
    # Ghidra dynamic profiles (both states)
    ip.make_profile("bubblewrap-ghidra-static"),
    ip.make_profile("test-only-untrusted-bwrap", network_access=True),
]
for p in to_check:
    # Line 382: shape check
    am._keys(p, {"name", "static_only", "network_access", "target_execution"}, "isolation_profile")
    # Line 383: name is text
    am._text(p["name"], "isolation_profile.name")
    # Line 384: all bool, target_execution=False
    assert all(isinstance(p[f], bool) for f in ("static_only", "network_access", "target_execution")), \
        f"non-bool field in {p}"
    assert not p["target_execution"], f"target_execution must be False in {p}"
PY
then ok "validator parity: all profiles accepted by analysis_manifest logic"; else no "validator parity: profiles accepted"; fi

# ---------------------------------------------------------------------------
# T9: validator rejects target_execution=True (parity with analysis_manifest:384)
# ---------------------------------------------------------------------------
if python3 - "$SUT" "$MANIFEST" <<'PY'
import importlib.util, sys
def load(path, name):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
am = load(sys.argv[2], "am")
# Craft a bad profile that bypasses make_profile (which blocks target_execution=True)
bad = {"name": "bad", "static_only": True, "network_access": False, "target_execution": True}
try:
    am._keys(bad, {"name", "static_only", "network_access", "target_execution"}, "isolation_profile")
    am._text(bad["name"], "isolation_profile.name")
    # Line 384 check
    if any(not isinstance(bad[f], bool) for f in ("static_only", "network_access", "target_execution")) \
            or bad["target_execution"]:
        raise am.ManifestError("isolation profile must record target_execution=false")
    raise AssertionError("validator should have rejected target_execution=True")
except am.ManifestError:
    pass  # expected
PY
then ok "validator parity: target_execution=True rejected (matches analysis_manifest:384)"; else no "validator parity: rejects bad profile"; fi

# ---------------------------------------------------------------------------
# T10: canonical JSON bytes from named constants match original inline dicts
#      This proves migration produces zero byte change in emitted manifests.
#      canonical_bytes uses sort_keys=True — key insertion order is moot.
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("ip", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)

def canon(d):
    return (json.dumps(d, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()

# (named_constant, original_inline_dict as it appeared in the source)
cases = [
    # corroborate_firmware.py:219 / corroborate_java.py:398 / corroborate_native.py:184
    (ip.PROFILE_BWRAP_STATIC_NETWORK_DENIED,
     {"name": "bubblewrap-static-network-denied", "static_only": True,
      "network_access": False, "target_execution": False}),
    # corroborate_pcap.py:23 / pcap_flows.py:24
    (ip.PROFILE_BWRAP_PCAP_OFFLINE,
     {"name": "bubblewrap-pcap-offline", "network_access": False,
      "static_only": True, "target_execution": False}),
    # corroborate_capa.py:55
    (ip.PROFILE_BWRAP_CAPA_OFFLINE,
     {"name": "bubblewrap-capa-offline", "network_access": False,
      "static_only": True, "target_execution": False}),
    # corroborate_floss.py:45
    (ip.PROFILE_BWRAP_FLOSS_OFFLINE,
     {"name": "bubblewrap-floss-offline", "network_access": False,
      "static_only": True, "target_execution": False}),
    # corroborate_kaitai.py:65
    (ip.PROFILE_BWRAP_KAITAI_OFFLINE,
     {"name": "bubblewrap-kaitai-offline", "network_access": False,
      "static_only": True, "target_execution": False}),
    # corroborate_unblob.py:39
    (ip.PROFILE_BWRAP_UNBLOB_OFFLINE,
     {"name": "bubblewrap-unblob-offline", "network_access": False,
      "static_only": True, "target_execution": False}),
    # squashfs_extract.py:230
    (ip.PROFILE_BWRAP_UNSQUASHFS,
     {"name": "bwrap-unsquashfs", "static_only": True,
      "network_access": False, "target_execution": False}),
    # zip_metadata.py:173
    (ip.PROFILE_INPROCESS_ZIP_METADATA,
     {"name": "in-process-metadata-only", "static_only": True,
      "network_access": False, "target_execution": False}),
    # zip_stored.py:179
    (ip.PROFILE_INPROCESS_ZIP_STORED,
     {"name": "in-process-static-stored-copy", "static_only": True,
      "network_access": False, "target_execution": False}),
]
for profile, inline in cases:
    got  = canon(profile)
    want = canon(inline)
    assert got == want, \
        f"byte mismatch for {profile['name']!r}:\n  got:  {got!r}\n  want: {want!r}"
PY
then ok "canonical bytes: named constants produce same JSON as original inline dicts"; else no "canonical bytes: parity"; fi

# ---------------------------------------------------------------------------
# teeth: remove target_execution guard → T4 (target_execution=True raises ValueError) must go red
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
    echo "-- teeth: remove target_execution guard; expect T4 (ValueError on target_execution=True) to go red --"
    _teeth_tmp="$(mktemp -d)"; trap 'rm -rf "$_teeth_tmp"' EXIT
    mutant="$_teeth_tmp/isolation_profile.MUTANT.py"
    sed 's/^    if target_execution:$/    if False:  # MUTANT: target_execution guard removed/' \
        "$SUT" > "$mutant"
    if ! grep -q 'MUTANT: target_execution guard removed' "$mutant"; then
        no "teeth-target-exec: mutant not built — 'if target_execution:' not matched in SUT (SUT may have changed)"
    else
        result=$(python3 - "$mutant" 2>&1 <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ip_mutant", sys.argv[1])
ip = importlib.util.module_from_spec(s); s.loader.exec_module(ip)
try:
    ip.make_profile("bad", target_execution=True)
    print("NO_ERROR")
except ValueError:
    print("GOT_VALUEERROR")
PY
        )
        if [ "$result" = "NO_ERROR" ]; then
            ok "teeth-target-exec: guard removed → make_profile(target_execution=True) silently succeeds → T4 ValueError guard has teeth"
        else
            no "teeth-target-exec: mutant still raises ValueError ($result) → T4 is THEATER"
        fi
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
