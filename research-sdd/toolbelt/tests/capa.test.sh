#!/usr/bin/env bash
# tests/capa.test.sh — capa evidence adapter test suite (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based schema/cap/isolation assertions + unit tests.
#                    No capa spawn.  Always emits "== N passed · N failed ==".
#   slow           — real capa run; requires capa + bwrap + python3 + rules dir.
#   all            — both fast and slow paths.
#
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT="$TOOLBELT/corroborate-capa.sh"
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
_HAPPY_FIX="$(rsdd_lane_fixture capa happy)"
_CAPPED_FIX="$(rsdd_lane_fixture capa capped)"

# ---------------------------------------------------------------------------
# SLOW LANE — real capa run (tool required)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  # Tool-availability guard — informational skip for slow lane only.
  _slow_skip=0
  for _cmd in capa bwrap python3; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done

  if [[ "$_slow_skip" -eq 0 ]]; then
    _RULES_DIR="${RSDD_CAPA_RULES:-$HOME/.local/share/capa-rules}"
    if ! [ -d "$_RULES_DIR" ]; then
      echo "SLOW lane: rules dir absent: $_RULES_DIR; slow-lane tests skipped." >&2
      _slow_skip=1
    fi
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    _SLOW_ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$_SLOW_ROOT"' EXIT
    cp /bin/true "$_SLOW_ROOT/happy.elf"

    # T1: Happy path.
    _T1_OUT="$_SLOW_ROOT/out_t1"
    if run "$_SLOW_ROOT/happy.elf" "$_T1_OUT" --timeout 300 2>/dev/null \
      && [ -f "$_T1_OUT/capa-evidence.v1.json" ]; then
      ok "T1: happy path: evidence JSON produced"
    else
      no "T1: happy path"
    fi

    # T2: Evidence schema.
    if python3 - "$_T1_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "capa-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "capabilities" in d, "capabilities domain key missing"
c = d["capabilities"]
assert "total_count" in c and "total_sampled" in c, "count/sampled missing"
assert isinstance(c.get("truncated"), bool), "top-level truncated must be bool"
assert "items" in c, "items list missing"
for item in c.get("items", []):
    assert "name" in item and "namespace" in item, f"name/namespace missing: {item}"
    assert isinstance(item.get("attack_ids"), list), f"attack_ids must be list: {item}"
    assert isinstance(item.get("mbc_ids"), list), f"mbc_ids must be list: {item}"
    assert isinstance(item.get("match_count"), int), f"match_count must be int: {item}"
assert c.get("capa_version"), "capa_version must be non-empty"
assert c.get("rules_path_digest", "").startswith("sha256:"), "rules_path_digest bad"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
assert isinstance(d["limitations"], list) and isinstance(d["errors"], list)
assert c["total_count"] >= 1, f"expected >=1 capability on /bin/true, got {c['total_count']}"
print(f"OK: schema={d['schema']} status={d['status']} total_count={c['total_count']}")
PY
    then ok "T2: evidence schema: required fields, capabilities structure, envelope"
    else no "T2: evidence schema"
    fi

    # T3: Determinism.
    _T3_OUT="$_SLOW_ROOT/out_t3"
    if run "$_SLOW_ROOT/happy.elf" "$_T3_OUT" --timeout 300 2>/dev/null \
      && cmp -s "$_T1_OUT/capa-evidence.v1.json" "$_T3_OUT/capa-evidence.v1.json"; then
      ok "T3: determinism: two runs produce byte-identical evidence"
    else
      no "T3: determinism"
    fi

    # T4: Capability cap.
    _T4_OUT="$_SLOW_ROOT/out_t4"
    if run "$_SLOW_ROOT/happy.elf" "$_T4_OUT" --max-capabilities 1 --timeout 300 2>/dev/null \
      && python3 - "$_T4_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["capabilities"]; lims = d.get("limitations", [])
assert c["total_sampled"] <= 1, f"cap not enforced: total_sampled={c['total_sampled']}"
assert c["truncated"] == True, f"truncated must be True, got {c['truncated']!r}"
assert any("capability cap" in l or "max-capabilities" in l for l in lims), \
    f"no cap limitation: {lims}"
print(f"OK: total_sampled={c['total_sampled']}, truncated=True, limitation present")
PY
    then ok "T4: capability cap: bounded, truncated=True, limitation recorded"
    else no "T4: capability cap"
    fi

    # T8: Output-dir-exists.
    mkdir -p "$_SLOW_ROOT/already_exists"
    if ! run "$_SLOW_ROOT/happy.elf" "$_SLOW_ROOT/already_exists" --timeout 10 2>/dev/null \
      && [ ! -f "$_SLOW_ROOT/already_exists/capa-evidence.v1.json" ]; then
      ok "T8: output-dir-exists rejected fail-closed"
    else no "T8: output-dir-exists"; fi

    # T9: Rules-dir missing.
    if ! run "$_SLOW_ROOT/happy.elf" "$_SLOW_ROOT/out_t9" \
        --rules /nonexistent/capa-rules --timeout 10 2>/dev/null \
      && [ ! -f "$_SLOW_ROOT/out_t9/capa-evidence.v1.json" ]; then
      ok "T9: rules-dir missing: fail-closed"
    else no "T9: rules-dir missing"; fi

    # T10: Rules-dir symlink.
    ln -s "$_RULES_DIR" "$_SLOW_ROOT/rules_symlink"
    if ! run "$_SLOW_ROOT/happy.elf" "$_SLOW_ROOT/out_t10" \
        --rules "$_SLOW_ROOT/rules_symlink" --timeout 10 2>/dev/null \
      && [ ! -f "$_SLOW_ROOT/out_t10/capa-evidence.v1.json" ]; then
      ok "T10: rules-dir symlink: fail-closed"
    else no "T10: rules-dir symlink"; fi

    # T11: Rules-dir without .yml files.
    mkdir -p "$_SLOW_ROOT/empty_rules_dir"
    if ! run "$_SLOW_ROOT/happy.elf" "$_SLOW_ROOT/out_t11" \
        --rules "$_SLOW_ROOT/empty_rules_dir" --timeout 10 2>/dev/null \
      && [ ! -f "$_SLOW_ROOT/out_t11/capa-evidence.v1.json" ]; then
      ok "T11: rules-dir without .yml files: fail-closed"
    else no "T11: rules-dir not a capa rules dir"; fi

    # T12: Isolation profile (CONTAINMENT).
    if python3 - "$_T1_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
c = d.get("capabilities", {})
assert c.get("capa_version"), "capa_version must be non-empty"
print(f"OK: isolation profile={profile}, capa_version={c['capa_version']!r}")
PY
    then ok "T12: isolation: network-denial profile, launcher identity, capa_version"
    else no "T12: isolation profile"
    fi

    # T13: Analysis manifest.
    if python3 "$MANIFEST" validate "$_T1_OUT/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
      && python3 "$MANIFEST" verify --root "$_T1_OUT" \
          "$_T1_OUT/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
      ok "T13: analysis manifest validates and verifies"
    else no "T13: analysis manifest"; fi

    # T14: Timeout visibility (flake-proof: skip when capa finishes in <1s).
    _T14_OUT="$_SLOW_ROOT/out_t14"; _T14_EXIT=0
    run "$_SLOW_ROOT/happy.elf" "$_T14_OUT" --timeout 1 2>/dev/null || _T14_EXIT=$?
    if [ "$_T14_EXIT" -eq 0 ]; then
      echo "  SKIP  T14: capa finished in <1s (flake-proof skip)"
    elif [ "$_T14_EXIT" -eq 2 ]; then
      no "T14: adapter fatal error (exit 2)"
    elif [ -f "$_T14_OUT/capa-evidence.v1.json" ]; then
      if python3 - "$_T14_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed on timeout, got {d.get('status')!r}"
assert "timeout" in d.get("errors", []), f"timeout not in errors: {d.get('errors')}"
c = d.get("capabilities", {})
assert c.get("truncated") == True, f"capabilities.truncated must be True on timeout"
assert any("timeout" in l for l in d.get("limitations", [])), "no timeout limitation"
print("OK: status=failed, timeout in errors, capabilities.truncated=True")
PY
      then ok "T14: --timeout 1: status=failed, capabilities.truncated=True, limitation"
      else no "T14: timeout visibility"
      fi
    else
      no "T14: evidence not published after timeout (exit $_T14_EXIT)"
    fi
  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based assertions (no tool spawn; sub-second)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: fixtures must exist before asserting against them.
  if [[ ! -f "$_HAPPY_FIX" ]]; then
    echo "FATAL: fixture missing: $_HAPPY_FIX" >&2
    echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite capa" >&2
    exit 1
  fi
  if [[ ! -f "$_CAPPED_FIX" ]]; then
    echo "FATAL: fixture missing: $_CAPPED_FIX" >&2
    echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite capa" >&2
    exit 1
  fi

  # T2-fast: Evidence schema from fixture.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "capa-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "capabilities" in d, "capabilities domain key missing"
c = d["capabilities"]
assert "total_count" in c and "total_sampled" in c, "count/sampled missing"
assert isinstance(c.get("truncated"), bool), "top-level truncated must be bool"
assert "items" in c, "items list missing"
for item in c.get("items", []):
    assert "name" in item and "namespace" in item, f"name/namespace missing: {item}"
    assert isinstance(item.get("attack_ids"), list), f"attack_ids must be list: {item}"
    assert isinstance(item.get("mbc_ids"), list), f"mbc_ids must be list: {item}"
    assert isinstance(item.get("match_count"), int), f"match_count must be int: {item}"
assert c.get("capa_version"), "capa_version must be non-empty"
assert c.get("rules_path_digest", "").startswith("sha256:"), "rules_path_digest bad"
for k in ("input", "isolation", "limitations", "errors"):
    assert k in d, f"{k} key missing"
assert isinstance(d["limitations"], list) and isinstance(d["errors"], list)
assert c["total_count"] >= 1, f"expected >=1 capability in fixture, got {c['total_count']}"
print(f"OK: schema={d['schema']} status={d['status']} total_count={c['total_count']}")
PY
  then ok "T2-fast: evidence schema (fixture): required fields, capabilities, envelope"
  else no "T2-fast: evidence schema (fixture)"
  fi

  # T4-fast: Capability cap from fixture.
  if python3 - "$_CAPPED_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["capabilities"]; lims = d.get("limitations", [])
assert c["total_sampled"] <= 1, f"cap not enforced: total_sampled={c['total_sampled']}"
assert c["truncated"] == True, f"truncated must be True, got {c['truncated']!r}"
assert any("capability cap" in l or "max-capabilities" in l for l in lims), \
    f"no cap limitation: {lims}"
print(f"OK: total_sampled={c['total_sampled']}, truncated=True, limitation present")
PY
  then ok "T4-fast: capability cap (fixture): bounded, truncated=True, limitation"
  else no "T4-fast: capability cap (fixture)"
  fi

  # T12-fast: Isolation profile (CONTAINMENT guard) from fixture.
  # Anti-#128: preserved in fast lane — checks the isolation profile recorded in the
  # evidence JSON, proving the SUT configured network denial and no code execution.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
c = d.get("capabilities", {})
assert c.get("capa_version"), "capa_version must be non-empty"
print(f"OK: isolation profile={profile}, capa_version={c['capa_version']!r}")
PY
  then ok "T12-fast: isolation (fixture): network-denial, no-exec profile (CONTAINMENT)"
  else no "T12-fast: isolation (fixture)"
  fi

fi # fast | all

# ---------------------------------------------------------------------------
# UNIT TESTS — run in all lanes (pure Python; no tool spawn; always sub-second)
# ---------------------------------------------------------------------------

# T5: Malformed JSON → (None, err_str); empty file → (None, None).
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_capa", toolbelt / "corroborate_capa.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / "stdout.txt"
    p.write_bytes(b'not json at all {{{{')
    val, err = m._read_stdout_json(p)
    assert val is None and isinstance(err, str) and err, f"malformed: expected (None, err), got {(val,err)!r}"
    e = Path(tmp) / "empty.txt"; e.write_bytes(b'')
    val2, err2 = m._read_stdout_json(e)
    assert val2 is None and err2 is None, f"empty: expected (None, None), got {(val2,err2)!r}"
    print("OK: (None, err) for malformed; (None, None) for empty")
PY
then ok "T5: malformed JSON: (None,err_str); empty file: (None,None)"
else no "T5: malformed JSON / empty file handling"
fi

# T6: Empty/no-capability inventory — _build_inventory(None) yields total_count=0.
if python3 - "$TOOLBELT" <<'PY'
import sys, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_capa", toolbelt / "corroborate_capa.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
inv, lims = m._build_inventory(None, max_capabilities=100)
assert inv["total_count"] == 0 and inv["total_sampled"] == 0, f"expected 0 counts"
assert inv["truncated"] == False and inv["items"] == [] and lims == [], f"unexpected: {inv}"
inv2, _ = m._build_inventory({"rules": {}}, max_capabilities=100)
assert inv2["total_count"] == 0, f"empty-rules: expected 0"
print(f"OK: empty inventory total_count=0, truncated=False, items=[]")
PY
then ok "T6: empty/no-capability inventory: total_count=0, truncated=False"
else no "T6: empty/no-capability inventory code path"
fi

# T7: O_NOFOLLOW — symlink at capa stdout path raises CapaError.
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_capa", toolbelt / "corroborate_capa.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    real = Path(tmp) / "real.txt"; real.write_bytes(b'{}')
    link = Path(tmp) / "stdout.txt"; link.symlink_to(real)
    try:
        m._read_stdout_json(link)
        print("FAIL: expected CapaError for symlink", file=sys.stderr); sys.exit(1)
    except m.CapaError:
        print("OK: CapaError raised for symlink at stdout path")
PY
then ok "T7: O_NOFOLLOW: symlink at stdout path raises CapaError"
else no "T7: O_NOFOLLOW symlink rejection"
fi

# T15-16: Scope guard + plausibility; run-truncation OR-wiring; non-dict rules.
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path
toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location("corroborate_capa", toolbelt / "corroborate_capa.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.path.insert(0, str(toolbelt / "lib"))
from adapter_helpers import run_truncation

# T15a: /home and /home/<user> must be shape-rejected by scope guard.
for broad in ["/home", "/home/someuser"]:
    try:
        m._rules_scope_guard(Path(broad))
        print(f"FAIL: {broad!r} not rejected", file=sys.stderr); sys.exit(1)
    except m.CapaError:
        pass

# T15b: stray-.yml dir (<50 ymls, no structural subdirs) — plausibility rejects.
with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / "ci.yml").write_text("# stray\n")
    try:
        m._validate_rules_dir(Path(tmp))
        print("FAIL: stray-yml dir not rejected", file=sys.stderr); sys.exit(1)
    except m.CapaError:
        pass

# T16a: run-truncation OR-wiring: synthetic timeout → truncated=True.
inv, _ = m._build_inventory(None, max_capabilities=100)
run_trunc, trunc_lims = run_truncation(["timeout"], "capa")
inv["truncated"] = inv["truncated"] or run_trunc
assert inv["truncated"] is True and any("timeout" in l for l in trunc_lims)

# T16b: non-dict rules field → schema-drift error, no AttributeError.
inv2, extra_lims = m._build_inventory({"rules": ["list"]}, max_capabilities=100)
assert inv2["total_count"] == 0 and extra_lims, f"expected schema-drift error"

print(f"OK: scope/plausibility guards; run-trunc wiring; non-dict schema-drift")
PY
then ok "T15-16: scope guard + plausibility; run-truncation wiring; non-dict rules"
else no "T15-16: scope guard + plausibility / run-truncation wiring / non-dict rules"
fi

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: mutation controls (fast-lane scope-guard assertion bites) --"

  # teeth-1: disable scope guard in corroborate_capa.py.
  # Mutation: the raise inside _rules_scope_guard becomes a return (no-op).
  # T15a then fails: /home is no longer rejected → test exits 1 (RED = teeth confirmed).
  _MUT_DIR="$(mktemp -d)"
  _MUT_PY="$_MUT_DIR/corroborate_capa.py"

  # Verify the mutation target exists before applying (abort if SUT changed).
  if ! grep -qF \
      'raise CapaError(f"--rules path rejected by bind-scope guard: {exc}") from exc' \
      "$TOOLBELT/corroborate_capa.py"; then
    no "teeth-1: mutation target not found in SUT (SUT changed?); cannot prove teeth"
  else
    sed 's|raise CapaError(f"--rules path rejected by bind-scope guard: {exc}") from exc|return  # mutant: scope guard disabled|g' \
      "$TOOLBELT/corroborate_capa.py" > "$_MUT_PY"

    _teeth_rc=0
    # Pass both the mutant dir and the real toolbelt so lib/ imports resolve correctly.
    python3 - "$_MUT_DIR" "$TOOLBELT" <<'PY' || _teeth_rc=$?
import sys, importlib.util
from pathlib import Path

mut_dir  = Path(sys.argv[1]).resolve()
toolbelt = Path(sys.argv[2]).resolve()

# Add real toolbelt to sys.path BEFORE importing the mutant so that when the
# mutant module does `from lib.adapter_core import ...` it finds the real lib/.
# (The mutant will also insert mut_dir at sys.path[0] during module exec; lib/
# resolution still falls through to toolbelt when mut_dir/lib/ does not exist.)
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_capa_mut", mut_dir / "corroborate_capa.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Run T15a assertion against the mutant module:
# /home should be rejected (CapaError); with the mutation the guard is disabled.
for broad in ["/home", "/home/someuser"]:
    try:
        m._rules_scope_guard(Path(broad))
        # No CapaError raised: mutation disabled the scope guard → assertion fails.
        print(f"T15a: mutant allowed {broad!r} (no CapaError) — assertion BITES",
              file=sys.stderr)
        sys.exit(1)  # test goes RED = teeth confirmed
    except m.CapaError:
        pass  # scope guard still fires despite mutation → mutation had no effect here

# All broad paths raised CapaError despite mutation → test would stay GREEN → no teeth.
print("T15a: all broad paths still rejected despite mutation — teeth missing",
      file=sys.stderr)
sys.exit(0)  # test stays GREEN = teeth missing
PY

    if [[ "$_teeth_rc" -ne 0 ]]; then
      ok "teeth-1: T15a goes RED with mutant scope guard: fast-lane assertion bites"
    else
      no "teeth-1: T15a stayed GREEN with mutant: fast-lane assertion has no teeth"
    fi
  fi

  rm -rf "$_MUT_DIR"
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
