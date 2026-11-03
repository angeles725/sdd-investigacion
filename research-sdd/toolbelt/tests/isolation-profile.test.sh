#!/usr/bin/env bash
# isolation-profile.test.sh — black-box tests of lib/isolation_profile.py, the Python entry point.
#
# The module was ported to Go (internal/core/adapter, kit issues #2390, #2421) and its behaviour is pinned there by
# parity tests that load THIS module and compare every make_profile() outcome and every PROFILE_*
# constant with the Go port (TestMakeProfile*, TestParityMakeProfile, TestParityNamedProfileConstants).
# What stays here is what the Go tests cannot see: the Python module itself, imported the way the ten
# Python adapters import it, still refuses target_execution=True and still carries the exact sandbox
# posture of every named constant. The factory defaults/overrides, name validation, key-shape,
# validator-parity and canonical-bytes cases moved to the Go parity tests.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/isolation_profile.py"

[ -f "$SUT" ]      || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

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
# teeth: remove target_execution guard → T4 (target_execution=True raises ValueError) must go red
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
    echo "-- teeth: remove target_execution guard; expect T4 (ValueError on target_execution=True) to go red --"
    _teeth_tmp="$(mktemp -d)"; trap 'rm -rf "$_teeth_tmp"' EXIT
    mutant="$_teeth_tmp/isolation_profile.MUTANT.py"
    # python mutant: MUTANT_SYNTAX=none skips bash -n; the helper still refuses empty / no-op / live-tree.
    # shellcheck source=lib/mutant.sh
    . "$HERE/lib/mutant.sh"
    MUTANT_SYNTAX=none mutant_sed "$SUT" "$mutant" \
        's/^    if target_execution:$/    if False:  # MUTANT: target_execution guard removed/' || true
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
