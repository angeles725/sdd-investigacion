#!/usr/bin/env bash
# Test suite for corroborate-ifc.sh (ifc-evidence.v1)
# SENTINEL-NO-TEETH-BANNER (do not remove — run-all.sh teeth coverage)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-ifc.sh"
MANIFEST="$HERE/../analysis_manifest.py"
# FIXTURES is assigned below after ROOT is created — generation goes into tmpdir

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
# Build fixtures into tmpdir — never into the committed tests/fixtures tree
FIXTURES="$ROOT/ifc_fixtures"
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
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth || exit 2
# The mutant is a python file: skip the bash -n check (empty, identical, live-tree, symlink and
# dead-stage refusals still apply).
export RSDD_IFC_PY

# Locate the outer adapter (sibling of SUT)
SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/corroborate_ifc.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  corroborate_ifc.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi

# ONE mutation in a temp toolbelt copy: reverse the sort key in _build_entity_histogram from
# (-count, type) to (+count, type). The tooth runs the adapter on the valid fixture and reports the
# histogram order; the original must report descending (rc 0) and the mutant must report broken.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
cat > "$MUTDIR/order_check.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d['ifc']['entity_histogram']['items']
desc = all(items[i]['count'] >= items[i+1]['count'] for i in range(len(items) - 1))
print("SORT: descending" if desc else "SORT: broken")
PY
# run_check.sh ADAPTER FIXTURE CHECK.py — run the adapter in a fresh scratch dir, then the order check.
# The scratch dir is removed on every path (EXIT trap); an adapter failure exits RUN_FAILED_RC with
# the adapter's own stderr on the output, so a failing tooth shows its cause.
cat > "$MUTDIR/run_check.sh" <<'SH'
#!/usr/bin/env bash
RUN_FAILED_RC=9   # distinct from the order check's own codes, so a crashed adapter is not read as a verdict
o="$(mktemp -d)"; trap 'rm -rf "$o"' EXIT
if ! python3 "$1" --manifest-cli "$(dirname "$1")/analysis_manifest.py" --input "$2" --output "$o/out" >/dev/null 2>"$o/err"; then
  echo "RUN-FAILED: adapter exited non-zero; stderr follows"; cat "$o/err"; exit "$RUN_FAILED_RC"
fi
python3 "$3" "$o/out/ifc-evidence.v1.json"
SH
if MUTANT_SYNTAX=none mutant_chain "sort-key mutation" "$ORIG_PY" "$MUTDIR/corroborate_ifc.py" "s/-x\['count'\]/x['count']/"; then
  if mutant_tooth "teeth: histogram sort-key mutation breaks count-descending order" 0 0 \
      "$MUTDIR/corroborate_ifc.py" --orig "$ORIG_PY" \
      --good-has 'SORT: descending' --bad-has 'SORT: broken' --bad-lacks 'SORT: descending' -- \
      bash "$MUTDIR/run_check.sh" \
      @SUT@ "$FIXTURES/valid.ifc" "$MUTDIR/order_check.py"; then
    pass=$((pass+1))
  else fail=$((fail+1)); fi
else
  fail=$((fail+1))
fi
rm -rf "$MUTDIR"

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
