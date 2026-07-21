#!/usr/bin/env bash
# tests/capa.test.sh — capa evidence adapter test suite
# House style: mirrors floss.test.sh.
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-capa.sh"
MANIFEST="$HERE/../analysis_manifest.py"

# RED guard — exit 2 when the script-under-test does not exist yet.
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in capa bwrap python3; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: capa tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

# Rules-dir check — skip gracefully when capa rules are absent.
_RULES_DIR="${RSDD_CAPA_RULES:-$HOME/.local/share/capa-rules}"
if ! [ -d "$_RULES_DIR" ]; then
  echo "SKIP: capa tests (rules dir absent: $_RULES_DIR)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# happy.elf: copy of /bin/true — a small ELF that capa analyzes successfully
# and reliably matches ≥1 capability rule (write file on Linux, terminate
# process, etc.).  Using an existing system binary avoids build toolchain deps.
cp /bin/true "$ROOT/happy.elf"

# ---------------------------------------------------------------------------
# T1: Happy path — capa runs on happy.elf and evidence JSON is produced.
# ---------------------------------------------------------------------------
_T1_OUT="$ROOT/out_t1"
if run "$ROOT/happy.elf" "$_T1_OUT" --timeout 300 2>/dev/null \
  && [ -f "$_T1_OUT/capa-evidence.v1.json" ]; then
  ok "T1: happy path: evidence JSON produced"
else
  no "T1: happy path"
fi

# ---------------------------------------------------------------------------
# T2: Evidence schema — required fields, capabilities structure, envelope keys.
# ---------------------------------------------------------------------------
if python3 - "$_T1_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "capa-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "capabilities" in d, "capabilities domain key missing"
c = d["capabilities"]
# Required capability inventory fields
assert "total_count" in c, "total_count missing"
assert "total_sampled" in c, "total_sampled missing"
assert isinstance(c.get("truncated"), bool), "top-level truncated must be bool"
assert "items" in c, "items list missing"
# Each item must have required fields
for item in c.get("items", []):
    assert "name" in item, f"name missing: {item}"
    assert "namespace" in item, f"namespace missing: {item}"
    assert isinstance(item.get("attack_ids"), list), f"attack_ids must be list: {item}"
    assert isinstance(item.get("mbc_ids"), list), f"mbc_ids must be list: {item}"
    assert isinstance(item.get("match_count"), int), f"match_count must be int: {item}"
# Metadata fields
assert "capa_version" in c, "capa_version missing"
assert c["capa_version"], "capa_version must be non-empty"
assert "rules_path_digest" in c, "rules_path_digest missing"
assert c["rules_path_digest"].startswith("sha256:"), f"rules_path_digest must be sha256 digest: {c.get('rules_path_digest')}"
# Standard envelope keys
assert "input" in d, "input key missing"
assert "isolation" in d, "isolation key missing"
assert "limitations" in d, "limitations key missing"
assert "errors" in d, "errors key missing"
assert isinstance(d["limitations"], list), "limitations must be list"
assert isinstance(d["errors"], list), "errors must be list"
# Must have ≥1 capability (happy.elf is /bin/true which reliably triggers rules)
assert c["total_count"] >= 1, f"expected ≥1 capability on happy.elf, got {c['total_count']}"
print(f"OK: schema={d['schema']} status={d['status']} total_count={c['total_count']}")
PY
then ok "T2: evidence schema: required fields, capabilities structure, envelope"
else no "T2: evidence schema"
fi

# ---------------------------------------------------------------------------
# T3: Determinism — two runs on same input produce byte-identical evidence.
# ---------------------------------------------------------------------------
_T3_OUT="$ROOT/out_t3"
if run "$ROOT/happy.elf" "$_T3_OUT" --timeout 300 2>/dev/null \
  && cmp -s "$_T1_OUT/capa-evidence.v1.json" "$_T3_OUT/capa-evidence.v1.json"; then
  ok "T3: determinism: two runs on same fixture produce byte-identical evidence"
else
  no "T3: determinism"
fi

# ---------------------------------------------------------------------------
# T4: Capability cap — --max-capabilities=1 fires; total_sampled bounded;
#     truncated=True; at least one limitation records the capability cap.
# ---------------------------------------------------------------------------
_T4_OUT="$ROOT/out_t4"
if run "$ROOT/happy.elf" "$_T4_OUT" --max-capabilities 1 --timeout 300 2>/dev/null \
  && python3 - "$_T4_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["capabilities"]
lims = d.get("limitations", [])
# total_sampled must be bounded by --max-capabilities=1
assert c["total_sampled"] <= 1, f"cap not enforced: total_sampled={c['total_sampled']}"
assert c["truncated"] == True, f"truncated must be True when cap fires, got {c['truncated']!r}"
cap_hit = any("capability cap" in l or "max-capabilities" in l for l in lims)
assert cap_hit, f"no capability-cap limitation recorded: {lims}"
print(f"OK: total_sampled={c['total_sampled']}, truncated=True, limitation present")
PY
then ok "T4: capability cap: total_sampled bounded, truncated=True, limitation recorded"
else no "T4: capability cap"
fi

# ---------------------------------------------------------------------------
# T5: Malformed JSON on exit-0 → fail-closed (status=failed, error recorded).
# Unit-tests _read_stdout_json() directly: non-empty malformed file must return
# (None, error_str) — never silently promoted to empty inventory.
# Also tests empty file → (None, None).
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_capa", toolbelt / "corroborate_capa.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as tmp:
    # Malformed JSON — must return (None, error_str)
    malformed = Path(tmp) / "stdout.txt"
    malformed.write_bytes(b'not json at all {{{{')
    result = m._read_stdout_json(malformed)
    assert isinstance(result, tuple) and len(result) == 2, \
        f"expected 2-tuple, got {result!r}"
    val, err = result
    assert val is None, f"expected None for malformed JSON, got {val!r}"
    assert isinstance(err, str) and err, \
        f"expected non-empty error str for malformed JSON, got {err!r}"

    # Empty file — must return (None, None)
    empty = Path(tmp) / "empty.txt"
    empty.write_bytes(b'')
    result2 = m._read_stdout_json(empty)
    val2, err2 = result2
    assert val2 is None, f"expected None for empty file, got {val2!r}"
    assert err2 is None, f"expected None error for empty file, got {err2!r}"

    print("OK: (None, err) for malformed; (None, None) for empty")
PY
then ok "T5: malformed JSON → (None,err_str); empty file → (None,None)"
else no "T5: malformed JSON / empty file handling"
fi

# ---------------------------------------------------------------------------
# T6: Empty/no-capability inventory code path — unit-tests _build_inventory
#     directly with None input: must produce status=complete empty inventory.
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_capa", toolbelt / "corroborate_capa.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# None → zero capabilities (capa produced no JSON or empty rules)
inv, extra_lims = m._build_inventory(None, max_capabilities=100)
assert inv["total_count"] == 0, f"expected total_count=0, got {inv['total_count']}"
assert inv["total_sampled"] == 0, f"expected total_sampled=0, got {inv['total_sampled']}"
assert inv["truncated"] == False, "expected truncated=False for empty inventory"
assert inv["items"] == [], f"expected empty items, got {inv['items']}"
assert extra_lims == [], f"expected no extra limitations, got {extra_lims}"

# Empty rules dict → same as None
inv2, _ = m._build_inventory({"rules": {}}, max_capabilities=100)
assert inv2["total_count"] == 0, f"empty-rules: expected 0, got {inv2['total_count']}"

print(f"OK: empty inventory total_count=0, truncated=False, items=[]")
PY
then ok "T6: empty/no-capability inventory: total_count=0, truncated=False"
else no "T6: empty/no-capability inventory code path"
fi

# ---------------------------------------------------------------------------
# T7: O_NOFOLLOW — symlink at capa stdout path raises CapaError.
# Unit-tests _read_stdout_json() directly.
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_capa", toolbelt / "corroborate_capa.py"
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
        print("FAIL: expected CapaError for symlink, got no exception", file=sys.stderr)
        sys.exit(1)
    except m.CapaError:
        print("OK: CapaError raised for symlink at stdout path")
PY
then ok "T7: O_NOFOLLOW: symlink at stdout path raises CapaError"
else no "T7: O_NOFOLLOW symlink rejection"
fi

# ---------------------------------------------------------------------------
# T8: Output-dir-exists — adapter fails closed; no evidence published.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/already_exists"
if ! run "$ROOT/happy.elf" "$ROOT/already_exists" --timeout 10 2>/dev/null \
  && [ ! -f "$ROOT/already_exists/capa-evidence.v1.json" ]; then
  ok "T8: output-dir-exists rejected fail-closed; no evidence published"
else
  no "T8: output-dir-exists"
fi

# ---------------------------------------------------------------------------
# T9: Rules-dir missing — adapter fails closed before running capa.
# ---------------------------------------------------------------------------
if ! run "$ROOT/happy.elf" "$ROOT/out_t9" --rules /nonexistent/capa-rules --timeout 10 2>/dev/null \
  && [ ! -f "$ROOT/out_t9/capa-evidence.v1.json" ]; then
  ok "T9: rules-dir missing → fail-closed (exit non-zero, no evidence)"
else
  no "T9: rules-dir missing"
fi

# ---------------------------------------------------------------------------
# T10: Rules-dir is a symlink — adapter rejects it fail-closed.
# ---------------------------------------------------------------------------
ln -s "$_RULES_DIR" "$ROOT/rules_symlink"
if ! run "$ROOT/happy.elf" "$ROOT/out_t10" --rules "$ROOT/rules_symlink" --timeout 10 2>/dev/null \
  && [ ! -f "$ROOT/out_t10/capa-evidence.v1.json" ]; then
  ok "T10: rules-dir symlink → fail-closed (exit non-zero, no evidence)"
else
  no "T10: rules-dir symlink"
fi

# ---------------------------------------------------------------------------
# T11: Rules-dir not a capa rules dir (no .yml files) → fail-closed.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/empty_rules_dir"
if ! run "$ROOT/happy.elf" "$ROOT/out_t11" --rules "$ROOT/empty_rules_dir" --timeout 10 2>/dev/null \
  && [ ! -f "$ROOT/out_t11/capa-evidence.v1.json" ]; then
  ok "T11: rules-dir without .yml files → fail-closed"
else
  no "T11: rules-dir not a capa rules dir"
fi

# ---------------------------------------------------------------------------
# T12: Isolation profile — network_access=false, target_execution=false,
#      launcher identity recorded.
# ---------------------------------------------------------------------------
if python3 - "$_T1_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {})
profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
c = d.get("capabilities", {})
assert "capa_version" in c, "capa_version missing from capabilities domain"
assert c["capa_version"], "capa_version must be non-empty"
print(f"OK: isolation profile={profile}, capa_version={c['capa_version']!r}")
PY
then ok "T12: isolation: network-denial profile, launcher identity, capa_version recorded"
else no "T12: isolation profile"
fi

# ---------------------------------------------------------------------------
# T13: Analysis manifest validates and verifies.
# ---------------------------------------------------------------------------
if python3 "$MANIFEST" validate "$_T1_OUT/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
  && python3 "$MANIFEST" verify --root "$_T1_OUT" "$_T1_OUT/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
  ok "T13: analysis manifest validates and verifies"
else
  no "T13: analysis manifest"
fi

# ---------------------------------------------------------------------------
# T14: Timeout visibility — --timeout 1 must set capabilities.truncated=True
#      and record a timeout limitation.  Skip when capa finishes in <1s
#      (flake-proof: happy.elf is small enough to parse very quickly).
# ---------------------------------------------------------------------------
_T14_OUT="$ROOT/out_t14"
_T14_EXIT=0
run "$ROOT/happy.elf" "$_T14_OUT" --timeout 1 2>/dev/null || _T14_EXIT=$?
if [ "$_T14_EXIT" -eq 0 ]; then
  echo "  SKIP  T14: capa finished in <1s on happy.elf (too fast; flake-proof skip)"
elif [ "$_T14_EXIT" -eq 2 ]; then
  no "T14: adapter fatal error (exit 2); check capa installation"
elif [ -f "$_T14_OUT/capa-evidence.v1.json" ]; then
  if python3 - "$_T14_OUT/capa-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", \
    f"expected status=failed on timeout, got {d.get('status')!r}"
assert "timeout" in d.get("errors", []), \
    f"timeout not in errors: {d.get('errors')}"
c = d.get("capabilities", {})
assert c.get("truncated") == True, \
    f"capabilities.truncated must be True on timeout, got {c.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("timeout" in l for l in lims), \
    f"no timeout limitation: {lims}"
print(f"OK: status=failed, timeout in errors, capabilities.truncated=True, limitation present")
PY
  then ok "T14: --timeout 1 sets status=failed, capabilities.truncated=True, limitation"
  else no "T14: timeout visibility (evidence present but fields wrong)"
  fi
else
  no "T14: evidence not published after timeout (exit $_T14_EXIT)"
fi

# ---------------------------------------------------------------------------
# T15-16: Scope guard + plausibility; run-truncation OR-wiring; non-dict rules.
# T15 proves CRITICAL: broad /home paths and stray-.yml dirs must be rejected.
# T16 covers the run-truncation wiring deterministically (avoids T14 skip gap)
#     and non-dict 'rules' field handling (schema-drift, no AttributeError).
# ---------------------------------------------------------------------------
if python3 - "$HERE/.." <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location(
    "corroborate_capa", toolbelt / "corroborate_capa.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.path.insert(0, str(toolbelt / "lib"))
from adapter_helpers import run_truncation

# T15a: /home and /home/<user> are shape-rejected by scope guard (pure, no FS).
for broad in ["/home", "/home/someuser"]:
    try:
        m._rules_scope_guard(Path(broad))
        print(f"FAIL: {broad!r} should be scope-rejected", file=sys.stderr); sys.exit(1)
    except m.CapaError:
        pass

# T15b: stray-.yml dir (<50 ymls, no structural subdirs) → plausibility rejects.
with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / "ci.yml").write_text("# stray workflow\n")
    try:
        m._validate_rules_dir(Path(tmp))
        print("FAIL: stray-yml dir should be plausibility-rejected", file=sys.stderr); sys.exit(1)
    except m.CapaError:
        pass

# T16a: run-truncation OR-wiring: synthetic timeout → truncated=True.
inv, _ = m._build_inventory(None, max_capabilities=100)
run_trunc, trunc_lims = run_truncation(["timeout"], "capa")
inv["truncated"] = inv["truncated"] or run_trunc
assert inv["truncated"] is True, f"expected truncated=True, got {inv['truncated']!r}"
assert any("timeout" in l for l in trunc_lims), f"no timeout limitation: {trunc_lims}"

# T16b: non-dict rules field → schema-drift error, no AttributeError.
inv2, extra_lims = m._build_inventory({"rules": ["list"]}, max_capabilities=100)
assert inv2["total_count"] == 0, f"non-dict rules: expected 0, got {inv2['total_count']}"
assert extra_lims, f"expected schema-drift error in extra_lims, got {extra_lims!r}"

print(f"OK: scope/plausibility guards; run-trunc={inv['truncated']}; non-dict={extra_lims[0]!r}")
PY
then ok "T15-16: scope guard + plausibility; run-truncation wiring; non-dict rules"
else no "T15-16: scope guard + plausibility / run-truncation wiring / non-dict rules"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
