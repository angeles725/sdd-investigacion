#!/usr/bin/env bash
# Test suite for corroborate-ifc.sh (ifc-evidence.v1)
# SENTINEL-NO-TEETH-BANNER (do not remove — run-all.sh teeth coverage)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-ifc.sh"
MANIFEST="$HERE/../analysis_manifest.py"
FIXTURES="$HERE/fixtures/corroborate-ifc"

# ---------------------------------------------------------------------------
# Tool availability guards — skip cleanly when dependencies are absent
# ---------------------------------------------------------------------------
RSDD_IFC_PY="${RSDD_IFC_PY:-$HOME/.local/share/rsdd-ifc/bin/python}"
if ! "$RSDD_IFC_PY" -c "import ifcopenshell" 2>/dev/null; then
  echo "SKIP: ifcopenshell not found at $RSDD_IFC_PY — suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

_bwrap="${RSDD_BWRAP:-$(command -v bwrap 2>/dev/null || true)}"
if [ -z "$_bwrap" ]; then
  echo "SKIP: bwrap not in PATH and RSDD_BWRAP not set — suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$FIXTURES"

# ---------------------------------------------------------------------------
# Build fixtures programmatically (never inside a live target directory)
# ---------------------------------------------------------------------------
"$RSDD_IFC_PY" - "$FIXTURES" <<'PY'
import sys, os
import ifcopenshell

out = sys.argv[1]

# Fixture 1: valid IFC with multiple entity types at different counts
f = ifcopenshell.file(schema="IFC4")
for _ in range(3):
    e = f.create_entity("IfcWall")
    e.GlobalId = ifcopenshell.guid.new()
e = f.create_entity("IfcSpace")
e.GlobalId = ifcopenshell.guid.new()
f.write(os.path.join(out, "valid.ifc"))

# Fixture 2: valid IFC with zero user entities (schema headers only)
g = ifcopenshell.file(schema="IFC4")
g.write(os.path.join(out, "empty.ifc"))
PY

# ---------------------------------------------------------------------------
# T1: valid IFC → success, proper schema, sort order count-desc-then-name
# ---------------------------------------------------------------------------
if "$SUT" --input "$FIXTURES/valid.ifc" --output "$ROOT/t1" \
  && python3 - "$ROOT/t1/ifc-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'ifc-evidence.v1', f"wrong schema: {d['schema']}"
assert d['status'] == 'complete', f"expected complete, got: {d['status']}"
ifc = d['ifc']
assert ifc['schema_version'].startswith('IFC'), \
    f"bad schema_version: {ifc['schema_version']}"
h = ifc['entity_histogram']
assert isinstance(h['total_entities'], int), "total_entities not int"
assert h['total_entities'] >= 0, "total_entities negative"
assert isinstance(h['total_types'], int), "total_types not int"
assert isinstance(h['truncated'], bool), "truncated not bool"
assert isinstance(h['items'], list), "items not list"
# Sort invariant: items ordered by count desc, then type asc
items = h['items']
for i in range(len(items) - 1):
    a, b = items[i], items[i + 1]
    assert (a['count'], a['type']) >= (b['count'], b['type']) \
        or a['count'] > b['count'], \
        f"sort order violated at index {i}: {a} vs {b}"
PY
then ok "valid IFC: schema, status, histogram, sort-order count-desc-then-name"
else no "valid IFC"; fi

# ---------------------------------------------------------------------------
# T2: empty IFC → complete, total_entities present and is an int
# ---------------------------------------------------------------------------
if "$SUT" --input "$FIXTURES/empty.ifc" --output "$ROOT/t2" \
  && python3 - "$ROOT/t2/ifc-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'ifc-evidence.v1'
assert d['status'] == 'complete', f"expected complete, got: {d['status']}"
h = d['ifc']['entity_histogram']
assert 'total_entities' in h, "total_entities missing from empty IFC evidence"
assert isinstance(h['total_entities'], int), "total_entities not int"
assert isinstance(h['items'], list), "items not list"
PY
then ok "empty IFC: complete status, total_entities present"
else no "empty IFC"; fi

# ---------------------------------------------------------------------------
# T3: absent input → non-zero exit (stage_file fails)
# ---------------------------------------------------------------------------
if ! "$SUT" --input "$ROOT/does-not-exist.ifc" --output "$ROOT/t3" 2>/dev/null; then
  ok "absent input: non-zero exit"
else
  no "absent input should fail with non-zero exit"
fi

# ---------------------------------------------------------------------------
# T4: garbage file (not IFC) → non-zero exit or evidence with errors
# ---------------------------------------------------------------------------
printf 'GARBAGE DATA - NOT IFC\n' > "$ROOT/garbage.ifc"
_t4_json="$ROOT/t4/ifc-evidence.v1.json"
if "$SUT" --input "$ROOT/garbage.ifc" --output "$ROOT/t4" 2>/dev/null; then
  # exit 0 is acceptable only when evidence has errors recorded
  if python3 - "$_t4_json" <<'PY' 2>/dev/null; then
import json, sys, os
if not os.path.exists(sys.argv[1]):
    sys.exit(1)
d = json.load(open(sys.argv[1]))
assert d.get('errors') or d.get('ifc', {}).get('entity_histogram', {}).get('parse_error'), \
    "garbage input: errors or parse_error expected"
PY
    ok "garbage file: parse error recorded in evidence"
  else
    no "garbage file: exit 0 but no error in evidence"
  fi
else
  ok "garbage file: non-zero exit (parse error)"
fi

# ---------------------------------------------------------------------------
# T5: determinism — two runs produce byte-identical evidence JSON
# ---------------------------------------------------------------------------
if "$SUT" --input "$FIXTURES/valid.ifc" --output "$ROOT/det_a" \
  && "$SUT" --input "$FIXTURES/valid.ifc" --output "$ROOT/det_b" \
  && cmp -s "$ROOT/det_a/ifc-evidence.v1.json" "$ROOT/det_b/ifc-evidence.v1.json"; then
  ok "determinism: two runs on same input produce byte-identical evidence"
else
  no "determinism"
fi

# ---------------------------------------------------------------------------
# T6: bwrap isolation markers present in driver_argv
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t1/ifc-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
argv = d.get('ifc', {}).get('driver_argv', [])
assert '--unshare-net' in argv, f"--unshare-net missing from driver_argv"
assert '--cap-drop' in argv, f"--cap-drop missing from driver_argv"
PY
then ok "bwrap isolation markers present in driver_argv"
else no "bwrap isolation markers"; fi

# ---------------------------------------------------------------------------
# T7: analysis manifest validates and artifact hashes verify
# ---------------------------------------------------------------------------
if python3 "$MANIFEST" validate "$ROOT/t1/engine/analysis-manifest.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/t1" \
       "$ROOT/t1/engine/analysis-manifest.v1.json"; then
  ok "analysis manifest validates and all artifact hashes verify"
else
  no "manifest validation/verification"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# --prove-teeth mutation control
# ---------------------------------------------------------------------------
echo "--- mutation control ---"
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

# Locate the outer adapter (sibling of SUT)
SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/corroborate_ifc.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  corroborate_ifc.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed · $MUT_PASS mut-pass · 1 mut-fail =="
  exit 1
fi

# Create a temp toolbelt copy with ONE mutation:
# Reverse the sort key in _build_entity_histogram from (-count, type) to (+count, type).
# Expected: the sort-order assertion in T1 fires because items are ascending not descending.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
# Patch: change the negation sign on count in the sort key
sed -i "s/-x\['count'\]/x['count']/" "$MUTDIR/corroborate_ifc.py"

# Verify the patch actually changed the file (if not, sed expression needs adjustment)
if cmp -s "$ORIG_PY" "$MUTDIR/corroborate_ifc.py"; then
  echo "  SKIP(mut)  sed patch had no effect — adjusting mutation"
  # Fallback: patch truncated field to always be True
  cp "$ORIG_PY" "$MUTDIR/corroborate_ifc.py"
  sed -i 's/cap_hit = total_types > max_types/cap_hit = True  # MUTANT/' \
    "$MUTDIR/corroborate_ifc.py"
fi

# Build a minimal test around the mutant:
# Run T1 via mutated toolbelt using RSDD_IFC_SCRIPT override.
# corroborate-ifc.sh uses $HERE/corroborate_ifc.py, so we call the mutant directly.
MUTOUT="$ROOT/mut_out"
if RSDD_IFC_PY="$RSDD_IFC_PY" \
   python3 "$MUTDIR/corroborate_ifc.py" \
     --manifest-cli "$MUTDIR/analysis_manifest.py" \
     --input "$FIXTURES/valid.ifc" \
     --output "$MUTOUT" 2>/dev/null; then
  # The mutant ran — check that the sort order invariant is VIOLATED
  if python3 - "$MUTOUT/ifc-evidence.v1.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
items = d['ifc']['entity_histogram']['items']
# Sort order must be VIOLATED by the mutation (ascending instead of descending)
# If fixture has entities with differing counts, ascending sort puts lowest first.
if len(items) > 1:
    all_desc = all(items[i]['count'] >= items[i+1]['count']
                   for i in range(len(items)-1))
    assert not all_desc, "mutant should break descending-count sort order"
sys.exit(0)
PY
  then
    # Python asserted NOT all_desc → the mutant broke the invariant (good)
    mut_ok "sort-key mutation detected: histogram is no longer count-descending"
  else
    # Python assertion passed → mutation was NOT detected by sort check.
    # Try the cap mutation instead: truncated should be True for non-capped fixture.
    if python3 - "$MUTOUT/ifc-evidence.v1.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['ifc']['entity_histogram']['truncated'], \
    "cap=True mutant should set truncated=True even for small fixture"
PY
    then
      mut_ok "cap=True mutation detected: truncated=True for small fixture"
    else
      mut_no "mutation not detected by either sort or cap check"
    fi
  fi
else
  # Mutant failed to run → wrong mutation, or mutation broke something structural
  mut_no "mutant failed to run (mutation too destructive or wrong)"
fi

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
