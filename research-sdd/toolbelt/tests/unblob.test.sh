#!/usr/bin/env bash
# tests/unblob.test.sh — unblob evidence adapter test suite (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — fixture-based schema/isolation/depth-cap assertions + unit tests.
#                    No unblob spawn.  Always emits "== N passed · N failed ==".
#   slow           — real unblob run; requires unblob, bwrap, python3.
#   all            — both fast and slow paths.
#
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT="$TOOLBELT/corroborate-unblob.sh"
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

# Fixture paths resolved here; existence checked in fast section.
_HAPPY_FIX="$(rsdd_lane_fixture unblob happy)"
_DEPTH_CAP_FIX="$(rsdd_lane_fixture unblob depth_capped)"

# ---------------------------------------------------------------------------
# SLOW LANE — real unblob run (tool required)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then

  _slow_skip=0
  for _cmd in unblob bwrap python3; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$ROOT"' EXIT

    # good.tgz: a tar.gz with 3 files — happy-path + determinism fixture.
    mkdir -p "$ROOT/tree"
    printf 'alpha' > "$ROOT/tree/a.txt"
    printf 'beta'  > "$ROOT/tree/b.txt"
    printf 'gamma' > "$ROOT/tree/c.txt"
    tar -C "$ROOT" -czf "$ROOT/good.tgz" tree 2>/dev/null

    # many.tgz: a tar.gz with 8 files — entry-cap fixture.
    mkdir -p "$ROOT/many"
    for _i in $(seq 1 8); do printf "file%s" "$_i" > "$ROOT/many/f$_i.txt"; done
    tar -C "$ROOT" -czf "$ROOT/many.tgz" many 2>/dev/null

    # big.tgz: a tar.gz with one file larger than 32 bytes — bytes-cap fixture.
    mkdir -p "$ROOT/big"
    dd if=/dev/urandom bs=1024 count=4 of="$ROOT/big/payload.bin" 2>/dev/null
    tar -C "$ROOT" -czf "$ROOT/big.tgz" big 2>/dev/null

    # text.bin: plain text — malformed / unrecognised input.
    printf 'this is not a firmware image\n' > "$ROOT/text.bin"

    # T1: Happy path.
    if run "$ROOT/good.tgz" "$ROOT/out_a" 2>/dev/null \
      && [ -f "$ROOT/out_a/unblob-evidence.v1.json" ]; then
      ok "T1: happy path: evidence JSON produced"
    else
      no "T1: happy path"
    fi

    # T2: Evidence schema.
    if python3 - "$ROOT/out_a/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "unblob-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "extraction" in d, "extraction key missing"
ex = d["extraction"]
entries = ex.get("entries", [])
assert isinstance(entries, list), "entries must be list"
paths = [e["path"] for e in entries]
assert paths == sorted(paths), f"entries not sorted: {paths}"
for e in entries:
    assert "path" in e and "size" in e and "sha256" in e and "depth" in e, f"missing fields: {e}"
    assert e["sha256"].startswith("sha256:"), f"bad sha256 prefix: {e['sha256']}"
    assert isinstance(e["size"], int) and e["size"] >= 0, f"bad size: {e['size']}"
    assert isinstance(e["depth"], int) and e["depth"] >= 1, f"bad depth: {e['depth']}"
assert "input" in d and "isolation" in d and "limitations" in d, "envelope keys missing"
launcher = d["isolation"].get("launcher", {})
assert launcher.get("path"), "launcher.path missing"
print(f"OK: {len(entries)} entries, schema={d['schema']}, status={d['status']}")
PY
    then ok "T2: evidence schema: required fields, sorted entries, sha256 prefixes"
    else no "T2: evidence schema"
    fi

    # T3: Determinism.
    if run "$ROOT/good.tgz" "$ROOT/out_b" 2>/dev/null \
      && cmp -s "$ROOT/out_a/unblob-evidence.v1.json" "$ROOT/out_b/unblob-evidence.v1.json"; then
      ok "T3: determinism: two runs on same fixture produce byte-identical evidence"
    else
      no "T3: determinism"
    fi

    # T4: Analysis manifest validates and verifies.
    if python3 "$MANIFEST" validate "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
      && python3 "$MANIFEST" verify --root "$ROOT/out_a" \
          "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
      ok "T4: analysis manifest validates and verifies"
    else
      no "T4: analysis manifest"
    fi

    # T5: Entry-cap truncation — max-entries=3 on many.tgz.
    if run "$ROOT/many.tgz" "$ROOT/out_cap" --max-entries 3 2>/dev/null \
      && python3 - "$ROOT/out_cap/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = d["extraction"]; entries = ex.get("entries", []); lims = d.get("limitations", [])
assert len(entries) <= 3, f"entry cap not enforced: {len(entries)} entries"
cap_hit = any("truncated" in s and "entry cap" in s for s in lims)
assert cap_hit, f"no entry-cap limitation recorded: {lims}"
print(f"OK: {len(entries)} entries, cap limitation present")
PY
    then ok "T5: max-entries cap: inventory truncated and limitation recorded"
    else no "T5: max-entries cap"
    fi

    # T6: Bytes-cap truncation — max-total-bytes=32 on big.tgz.
    if run "$ROOT/big.tgz" "$ROOT/out_bytes" --max-total-bytes 32 2>/dev/null \
      && python3 - "$ROOT/out_bytes/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
lims = d.get("limitations", [])
cap_hit = any("truncated" in s and "total-bytes" in s for s in lims)
assert cap_hit, f"no bytes-cap limitation recorded: {lims}"
print(f"OK: bytes-cap limitation present")
PY
    then ok "T6: max-total-bytes cap: limitation recorded"
    else no "T6: max-total-bytes cap"
    fi

    # T7: Output-dir-exists — fail-closed.
    mkdir -p "$ROOT/already_exists"
    if ! run "$ROOT/good.tgz" "$ROOT/already_exists" 2>/dev/null \
      && [ ! -f "$ROOT/already_exists/unblob-evidence.v1.json" ]; then
      ok "T7: output-dir-exists rejected fail-closed; no evidence published"
    else
      no "T7: output-dir-exists"
    fi

    # T8: Unrecognized input — valid empty-inventory evidence (status=complete, 0 entries).
    if run "$ROOT/text.bin" "$ROOT/out_text" 2>/dev/null \
      && python3 - "$ROOT/out_text/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "unblob-evidence.v1"
assert d.get("status") == "complete", f"expected status=complete, got {d.get('status')!r}"
ex = d.get("extraction", {})
assert ex.get("entries") == [], f"expected empty entries list"
assert ex.get("entry_count") == 0, f"expected entry_count=0"
assert not ex.get("truncated"), "truncated must be False"
print(f"OK: status={d['status']}, entry_count={ex.get('entry_count')}")
PY
    then ok "T8: malformed input: valid empty-inventory evidence (status=complete, 0 entries)"
    else no "T8: malformed input"
    fi

    # T9: Isolation profile — network_access=false, launcher bound.
    if python3 - "$ROOT/out_a/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
print(f"OK: isolation profile={profile}")
PY
    then ok "T9: isolation: network-denial profile and launcher identity recorded"
    else no "T9: isolation profile"
    fi

    # T10: Depth-cap truncation — depth cap fires and is visible in limitations.
    if run "$ROOT/good.tgz" "$ROOT/out_depthcap" --max-depth 2 2>/dev/null \
      && python3 - "$ROOT/out_depthcap/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = d["extraction"]; lims = d.get("limitations", [])
cap_hit = any("depth cap" in s for s in lims)
assert cap_hit, f"depth-cap limitation must appear when subdirs are pruned: {lims}"
assert ex.get("truncated") == True, f"truncated must be True when depth cap fires"
for e in ex.get("entries", []):
    assert e["depth"] <= 2, f"entry at depth {e['depth']} violates max_depth=2"
print(f"OK: depth-cap limitation present, truncated=True, entries bounded")
PY
    then ok "T10: max-depth cap: limitation recorded, truncated=True, entries bounded by depth"
    else no "T10: max-depth cap"
    fi

    # T11: Timeout visibility.
    _T11_OUT="$ROOT/out_timeout_unblob"; _T11_EXIT=0
    run "$ROOT/good.tgz" "$_T11_OUT" --timeout 1 2>/dev/null || _T11_EXIT=$?
    if [ "$_T11_EXIT" -eq 0 ]; then
      echo "  SKIP  T11: unblob finished in <1s on good.tgz (too fast; flake-proof skip)"
    elif [ "$_T11_EXIT" -eq 2 ]; then
      no "T11: adapter fatal error (exit 2)"
    elif [ -f "$_T11_OUT/unblob-evidence.v1.json" ]; then
      if python3 - "$_T11_OUT/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", f"expected status=failed on timeout"
assert "timeout" in d.get("errors", []), f"timeout not in errors: {d.get('errors')}"
ex = d.get("extraction", {})
assert ex.get("truncated") == True, f"extraction.truncated must be True on timeout"
lims = d.get("limitations", [])
assert any("timeout" in l for l in lims), f"no timeout limitation string: {lims}"
print(f"OK: status=failed, timeout in errors, extraction.truncated=True, limitation present")
PY
      then ok "T11: --timeout 1 sets status=failed, extraction.truncated=True, timeout limitation"
      else no "T11: timeout visibility"
      fi
    else
      no "T11: evidence not published after timeout (exit $_T11_EXIT)"
    fi
  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — fixture-based assertions (no tool spawn; sub-second)
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: fixtures must exist before asserting against them.
  for _fix in "$_HAPPY_FIX" "$_DEPTH_CAP_FIX"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite unblob" >&2
      exit 1
    fi
  done

  # T2-fast: Evidence schema from fixture.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "unblob-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "extraction" in d, "extraction key missing"
ex = d["extraction"]
entries = ex.get("entries", [])
assert isinstance(entries, list) and len(entries) > 0, "entries must be non-empty list"
paths = [e["path"] for e in entries]
assert paths == sorted(paths), f"entries not sorted: {paths}"
for e in entries:
    assert "path" in e and "size" in e and "sha256" in e and "depth" in e, f"missing fields: {e}"
    assert e["sha256"].startswith("sha256:"), f"bad sha256 prefix: {e['sha256']}"
    assert isinstance(e["size"], int) and e["size"] >= 0, f"bad size: {e['size']}"
assert "input" in d and "isolation" in d and "limitations" in d, "envelope keys missing"
print(f"OK: {len(entries)} entries, schema={d['schema']}, status={d['status']}")
PY
  then ok "T2-fast: evidence schema (fixture): required fields, sorted entries, sha256 prefixes"
  else no "T2-fast: evidence schema (fixture)"
  fi

  # T10-fast: Depth-cap from fixture.
  if python3 - "$_DEPTH_CAP_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = d["extraction"]; lims = d.get("limitations", [])
cap_hit = any("depth cap" in s for s in lims)
assert cap_hit, f"depth-cap limitation must appear in depth-capped fixture: {lims}"
assert ex.get("truncated") == True, f"truncated must be True in depth-capped fixture"
for e in ex.get("entries", []):
    assert e["depth"] <= 2, f"entry at depth {e['depth']} violates max_depth=2"
print(f"OK: depth-cap limitation present, truncated=True, {len(ex['entries'])} entries at depth<=2")
PY
  then ok "T10-fast: depth-cap (fixture): limitation present, truncated=True, entries bounded"
  else no "T10-fast: depth-cap (fixture)"
  fi

  # T9-fast: Isolation profile (CONTAINMENT guard) from fixture.
  # Anti-#128: preserved in fast lane — checks the isolation profile recorded in the
  # evidence JSON, proving the SUT configured network denial and no code execution.
  if python3 - "$_HAPPY_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {}); profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
print(f"OK: isolation profile={profile}")
PY
  then ok "T9-fast: isolation (fixture): network-denial, no-exec profile (CONTAINMENT)"
  else no "T9-fast: isolation (fixture)"
  fi

fi # fast | all

# ---------------------------------------------------------------------------
# UNIT TESTS — run in all lanes (pure Python; no tool spawn; always sub-second)
# ---------------------------------------------------------------------------

# T_unit: _walk_extracted records depth-cap limitation when dirs are pruned.
# This is the fast-lane teeth target: mutation removes the limitations.append()
# call → no "depth cap" in lims → assertion fails → RED.
if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile, importlib.util
from pathlib import Path

toolbelt = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(toolbelt))
spec = importlib.util.spec_from_file_location(
    "corroborate_unblob", toolbelt / "corroborate_unblob.py"
)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    # Two-level tree: root/top.txt (depth 1) and root/dir/file.txt (depth 2).
    (root / "top.txt").write_bytes(b"top-level")
    (root / "dir").mkdir()
    (root / "dir" / "file.txt").write_bytes(b"nested-file")

    # max_depth=1: root/dir should be pruned (file_depth_here=2 >= max_depth=1 fires
    # at dir_depth=0 because file_depth_here = dir_depth+1 = 1, and 1 >= 1).
    # Correction: depth check is file_depth_here >= max_depth.
    # dir_depth=0 (root itself), file_depth_here=1, max_depth=1: 1>=1 → prune dirs.
    entries, lims, _ = m._walk_extracted(
        root, max_entries=100, max_total_bytes=10 ** 6, max_depth=1
    )
    assert any("depth cap" in l for l in lims), \
        f"depth-cap limitation must be recorded when dirs are pruned: lims={lims}"
    # root/top.txt should still be included (file at depth 1)
    assert any("top.txt" in e["path"] for e in entries), \
        f"top.txt should be included at depth 1: {[e['path'] for e in entries]}"
    # root/dir/file.txt must NOT be included (beyond max_depth)
    assert not any("file.txt" in e["path"] for e in entries), \
        f"file.txt at depth 2 must be excluded: {[e['path'] for e in entries]}"

    print(f"OK: depth-cap limitation recorded; {len(entries)} entries at depth<=1")
PY
then ok "T_unit: _walk_extracted: depth-cap limitation recorded when dirs are pruned"
else no "T_unit: _walk_extracted depth-cap limitation recording"
fi

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: mutation controls (fast-lane depth-cap unit-test assertion bites) --"

  # teeth-1: remove depth-cap limitation recording in _walk_extracted.
  # Mutation: replace the unique content string with an empty string, so
  # limitations.append("") is called instead of appending the depth-cap message.
  # T_unit then asserts any("depth cap" in l ...) → no "depth cap" in "" → RED.
  _MUT_DIR="$(mktemp -d)"
  _MUT_PY="$_MUT_DIR/corroborate_unblob.py"

  if ! grep -qF 'f"inventory truncated: depth cap {max_depth} reached"' \
      "$TOOLBELT/corroborate_unblob.py"; then
    no "teeth-1: mutation target not found in SUT (SUT changed?); cannot prove teeth"
  else
    sed 's|f"inventory truncated: depth cap {max_depth} reached"|""  # mutant: depth-cap limitation omitted|g' \
      "$TOOLBELT/corroborate_unblob.py" > "$_MUT_PY"

    _teeth_rc=0
    python3 - "$_MUT_DIR" "$TOOLBELT" <<'PY' || _teeth_rc=$?
import sys, tempfile, importlib.util
from pathlib import Path

mut_dir  = Path(sys.argv[1]).resolve()
toolbelt = Path(sys.argv[2]).resolve()

# Add real toolbelt so lib/ imports resolve.
sys.path.insert(0, str(toolbelt))

spec = importlib.util.spec_from_file_location(
    "corroborate_unblob_mut", mut_dir / "corroborate_unblob.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "top.txt").write_bytes(b"top-level")
    (root / "dir").mkdir()
    (root / "dir" / "file.txt").write_bytes(b"nested-file")

    _, lims, _ = m._walk_extracted(
        root, max_entries=100, max_total_bytes=10 ** 6, max_depth=1
    )
    if not any("depth cap" in l for l in lims):
        # Mutant omitted the depth-cap limitation — assertion would fail → RED.
        print("T_unit: mutant omitted depth-cap limitation — assertion BITES",
              file=sys.stderr)
        sys.exit(1)  # test goes RED = teeth confirmed
    else:
        print("T_unit: depth-cap limitation still present despite mutation — teeth missing",
              file=sys.stderr)
        sys.exit(0)
PY

    if [[ "$_teeth_rc" -ne 0 ]]; then
      ok "teeth-1: T_unit goes RED with mutant (depth-cap limitation omitted): assertion bites"
    else
      no "teeth-1: T_unit stayed GREEN with mutant: assertion has no teeth"
    fi
  fi

  rm -rf "$_MUT_DIR"
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
