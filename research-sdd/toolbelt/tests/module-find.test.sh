#!/usr/bin/env bash
# Test suite for module-find.sh (module-find.v1)
# TDD: tests written first; run against non-existent SUT to confirm RED before GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../module-find.sh"
FIXTURES="$HERE/fixtures/module-find"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# Build hermetic fixture source trees (never inside a live target dir).
# Fixtures are written once and not regenerated if already present.
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import os, sys

out = sys.argv[1]

def write(p, content):
    """Write fixture file; skip if already present (idempotent)."""
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not os.path.exists(p):
        with open(p, 'w', encoding='utf-8') as f:
            f.write(content)

# slot-tree: a minimal Java module source with known annotations
# BSlotClass: single-line NiagaraProperty + multi-line NiagaraProperty + extends + action
write(os.path.join(out, 'slot-tree', 'BSlotClass.java'), '''\
package com.example;
public class BSlotClass extends BComponent {
    @NiagaraProperty(name = "enabled", type = "boolean", flags = Flags.SUMMARY)
    @NiagaraProperty(
        name = "setpoint",
        type = "baja:StatusNumeric",
        flags = Flags.SUMMARY | Flags.OPERATOR
    )
    @NiagaraAction(name = "reset", flags = Flags.OPERATOR)
    public void doReset() {}
}
''')

# BHelperClass: another class with a single action, no slots
write(os.path.join(out, 'slot-tree', 'BHelperClass.java'), '''\
package com.example;
public class BHelperClass extends BAbstractHelper {
    @NiagaraAction(name = "execute", flags = Flags.HIDDEN)
    public void doExecute() {}
}
''')

# dot-dir: must be pruned — annotations here must NOT appear in output
write(os.path.join(out, 'slot-tree', '.hidden', 'BNoise.java'), '''\
@NiagaraProperty(name = "noise", type = "boolean")
public class BNoise {}
''')

# empty-tree: a directory with no .java files (valid empty; proves instrument looked)
os.makedirs(os.path.join(out, 'empty-tree'), exist_ok=True)
write(os.path.join(out, 'empty-tree', 'README.txt'), 'no java here\n')  # non-.java file

# no-annotations: .java files exist but contain no @NiagaraProperty/@NiagaraAction
write(os.path.join(out, 'no-annotations', 'BPlain.java'), '''\
package com.example;
public class BPlain extends BBase {
    public void doNothing() {}
}
''')

PY

# ---------------------------------------------------------------------------
# Fixture generation for new test cases (container, comment-paren, isreg, unreadable, containment)
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY2'
import os, sys

out = sys.argv[1]

def write(p, content):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not os.path.exists(p):
        with open(p, 'w', encoding='utf-8') as f:
            f.write(content)

# container-tree: class with container-form @NiagaraProperties({...}) and @NiagaraActions({...})
# This is the BLOCKER fixture: tool must emit one record per nested annotation, not one total.
write(os.path.join(out, 'container-tree', 'BContainerClass.java'), '''\
package com.example;
public class BContainerClass extends BComponent {
    @NiagaraProperties({
        @NiagaraProperty(name = "alpha", type = "baja:StatusBoolean", flags = Flags.SUMMARY),
        @NiagaraProperty(name = "beta", type = "baja:StatusNumeric", flags = Flags.OPERATOR)
    })
    @NiagaraActions({
        @NiagaraAction(name = "startOp", flags = Flags.HIDDEN),
        @NiagaraAction(name = "stopOp", flags = Flags.OPERATOR)
    })
    public void doStartOp() {}
    public void doStopOp() {}
}
''')

# comment-paren-tree: a // comment containing an unbalanced ( inside an annotation body.
# Without the fix the paren-balance counter absorbs the next annotation line into the buffer,
# so only 'first' is emitted and 'second' is lost.
write(os.path.join(out, 'comment-paren-tree', 'BCommentParen.java'), '''\
package com.example;
public class BCommentParen extends BBase {
    @NiagaraProperty(name = "first", type = "boolean")  // trailing comment with ( unbalanced
    @NiagaraProperty(name = "second", type = "numeric")
    public void doSomething() {}
}
''')

# isreg-tree: one normal file and one .java that is a symlink (must be skipped by S_ISREG check).
# We cannot create the symlink here (Python os.symlink) because the target must exist at test time.
# The symlink is created in the shell test instead; only the normal file is created here.
write(os.path.join(out, 'isreg-tree', 'BReal.java'), '''\
package com.example;
public class BReal extends BBase {
    @NiagaraProperty(name = "realSlot", type = "boolean")
    public void doReal() {}
}
''')

# unreadable-tree: one .java file; the test will chmod 000 it before running the tool.
write(os.path.join(out, 'unreadable-tree', 'BUnreadable.java'), '''\
package com.example;
public class BUnreadable extends BBase {
    @NiagaraProperty(name = "hidden", type = "boolean")
    public void doHidden() {}
}
''')

PY2

# ---------------------------------------------------------------------------
# T1: absent source root → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" "$ROOT/no-such-dir" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent root: exit 2, no JSON"
else
  no "T1 absent root: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink root → exit 2 (symlink guard on source root)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/slot-tree" "$ROOT/sym-tree"
_t2_exit=0
"$SUT" "$ROOT/sym-tree" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink root: exit 2 (symlink guard)"
else
  no "T2 symlink root: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: non-directory input (regular file) → exit 2
# ---------------------------------------------------------------------------
echo "notadir" > "$ROOT/notadir.txt"
_t3_exit=0
"$SUT" "$ROOT/notadir.txt" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 2 ]; then
  ok "T3 non-directory input: exit 2"
else
  no "T3 non-directory input: expected exit 2, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: symlink root with trailing slash → exit 2
#     (os.lstat("link/") follows the link on POSIX; must strip trailing sep)
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" "$ROOT/sym-tree/" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 2 ]; then
  ok "T4 symlink root trailing slash: exit 2 (symlink guard fires with /)"
else
  no "T4 symlink root trailing slash: expected exit 2, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: empty source tree → exit 0, status:complete, scanned=0
#     Proves the instrument looked (scanned key present, not absent)
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" "$FIXTURES/empty-tree" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'module-find.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['scanned'] == 0, f"scanned must be 0 for empty tree, got {d.get('scanned')}"
assert d['slots'] == [], f"slots must be [] for empty tree"
assert d['actions'] == [], f"actions must be [] for empty tree"
assert d['truncated'] == False, f"truncated must be false"
PY
  then
    ok "T5 empty tree: exit 0, status:complete, scanned=0 (instrument looked)"
  else
    no "T5 empty tree: exit 0 but JSON validation failed"
  fi
else
  no "T5 empty tree: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: source tree with annotations → exit 0, exact slot/action names extracted
#     Verifies both single-line and multi-line annotations are parsed correctly.
#     Dot-dir (.hidden/) must be pruned (noise slot must not appear).
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" "$FIXTURES/slot-tree" --output "$ROOT/t6.json" 2>/dev/null \
  || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'module-find.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
# File count: BSlotClass.java + BHelperClass.java = 2 (dot-dir pruned)
assert d['scanned'] == 2, f"expected scanned=2, got {d.get('scanned')}"
# Slot names must include both single-line and multi-line annotations
slot_names = {s['slot'] for s in d['slots']}
assert 'enabled' in slot_names, \
    f"single-line @NiagaraProperty 'enabled' missing; slots={slot_names}"
assert 'setpoint' in slot_names, \
    f"multi-line @NiagaraProperty 'setpoint' missing; slots={slot_names}"
# Dot-dir noise must not appear
assert 'noise' not in slot_names, \
    f"dot-dir BNoise 'noise' slot must be pruned; got slots={slot_names}"
# Type of setpoint: paren-balance join must capture it
setpoint = next(s for s in d['slots'] if s['slot'] == 'setpoint')
assert setpoint['type'] == 'baja:StatusNumeric', \
    f"setpoint type must be 'baja:StatusNumeric', got {setpoint['type']!r}"
# Action names
action_names = {a['action'] for a in d['actions']}
assert 'reset' in action_names, f"action 'reset' missing; actions={action_names}"
assert 'execute' in action_names, f"action 'execute' missing; actions={action_names}"
# Extends
assert d['extends']['BSlotClass'] == 'BComponent', \
    f"extends BSlotClass->BComponent missing; got {d.get('extends')}"
assert d['extends']['BHelperClass'] == 'BAbstractHelper', \
    f"extends BHelperClass->BAbstractHelper missing"
PY
  then
    ok "T6 slot-tree: exact slot/action/extends extracted, dot-dir pruned"
  else
    no "T6 slot-tree: JSON validation failed"
  fi
else
  no "T6 slot-tree: expected exit 0, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: no-annotations tree → exit 0, scanned>0, slots=[], actions=[]
#     Distinguishes "no-match" from "empty tree" (scanned > 0 proves it looked)
# ---------------------------------------------------------------------------
_t7_exit=0
"$SUT" "$FIXTURES/no-annotations" --output "$ROOT/t7.json" 2>/dev/null \
  || _t7_exit=$?
if [ "$_t7_exit" -eq 0 ]; then
  if python3 - "$ROOT/t7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['scanned'] > 0, \
    f"scanned must be >0 (proves instrument looked at .java files), got {d.get('scanned')}"
assert d['slots'] == [], f"slots must be [] for no-annotations tree"
assert d['actions'] == [], f"actions must be [] for no-annotations tree"
PY
  then
    ok "T7 no-annotations: scanned>0 proves instrument looked, slots/actions empty"
  else
    no "T7 no-annotations: JSON validation failed"
  fi
else
  no "T7 no-annotations: expected exit 0, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: --output symlink → exit 2, victim file not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t8_exit=0
"$SUT" "$FIXTURES/slot-tree" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t8_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t8_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T8 output symlink: exit 2, victim not overwritten"
else
  no "T8 output symlink: expected exit 2 + victim intact, got exit $_t8_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T9: --output pre-existing file → exit 2 (O_CREAT|O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.json"
_t9_exit=0
"$SUT" "$FIXTURES/slot-tree" --output "$ROOT/pre_existing.json" \
  2>/dev/null || _t9_exit=$?
if [ "$_t9_exit" -eq 2 ]; then
  ok "T9 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T9 pre-existing output: expected exit 2, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: container form → EXACT sibling names extracted (blocker fix)
#      @NiagaraProperties({@NiagaraProperty(...),...}) must emit one record per nested annotation.
#      RED before fix: only the first annotation name is found (one name= search over whole buf).
#      GREEN after fix: per-fragment split emits one record each.
# ---------------------------------------------------------------------------
_t10_exit=0
"$SUT" "$FIXTURES/container-tree" --output "$ROOT/t10.json" 2>/dev/null \
  || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ]; then
  if python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
slot_names = {s['slot'] for s in d['slots']}
assert 'alpha' in slot_names, \
    f"container @NiagaraProperty 'alpha' missing; slots={slot_names}"
assert 'beta' in slot_names, \
    f"container @NiagaraProperty 'beta' missing; slots={slot_names}"
assert len(d['slots']) == 2, \
    f"expected exactly 2 slots (alpha, beta), got {len(d['slots'])}: {slot_names}"
action_names = {a['action'] for a in d['actions']}
assert 'startOp' in action_names, \
    f"container @NiagaraAction 'startOp' missing; actions={action_names}"
assert 'stopOp' in action_names, \
    f"container @NiagaraAction 'stopOp' missing; actions={action_names}"
assert len(d['actions']) == 2, \
    f"expected exactly 2 actions, got {len(d['actions'])}: {action_names}"
PY
  then
    ok "T10 container form: alpha+beta slots and startOp+stopOp actions extracted"
  else
    no "T10 container form: JSON validation failed (container split not implemented yet?)"
  fi
else
  no "T10 container form: expected exit 0, got $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: comment-paren → both 'first' and 'second' slots extracted
#      A // comment containing '(' must not inflate the paren-balance counter.
#      RED before fix: paren-balance absorbs the 'second' line into 'first' buffer.
#      GREEN after fix: comment parens stripped before counting.
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" "$FIXTURES/comment-paren-tree" --output "$ROOT/t11.json" 2>/dev/null \
  || _t11_exit=$?
if [ "$_t11_exit" -eq 0 ]; then
  if python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
slot_names = {s['slot'] for s in d['slots']}
assert 'first' in slot_names, \
    f"'first' slot missing; slots={slot_names}"
assert 'second' in slot_names, \
    f"'second' slot missing (comment-paren bug?); slots={slot_names}"
assert len(d['slots']) == 2, \
    f"expected exactly 2 slots, got {len(d['slots'])}: {slot_names}"
PY
  then
    ok "T11 comment-paren: both 'first' and 'second' slots extracted"
  else
    no "T11 comment-paren: JSON validation failed (comment-paren not stripped?)"
  fi
else
  no "T11 comment-paren: expected exit 0, got $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: S_ISREG — symlink .java inside tree skipped, normal .java counted
#      Creates a symlink .java in the isreg-tree and verifies scanned count = 1
#      (only the real BReal.java) and only 'realSlot' appears.
# ---------------------------------------------------------------------------
# Create symlink .java inside isreg-tree at test time (not in Python heredoc)
_isreg_dir="$FIXTURES/isreg-tree"
ln -sf "$FIXTURES/slot-tree/BSlotClass.java" "$_isreg_dir/BSymLink.java" 2>/dev/null || true
_t12_exit=0
"$SUT" "$_isreg_dir" --output "$ROOT/t12.json" 2>/dev/null \
  || _t12_exit=$?
if [ "$_t12_exit" -eq 0 ]; then
  if python3 - "$ROOT/t12.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['scanned'] == 1, \
    f"expected scanned=1 (symlink .java must be skipped), got {d.get('scanned')}"
slot_names = {s['slot'] for s in d['slots']}
assert slot_names == {'realSlot'}, \
    f"expected only 'realSlot', got {slot_names}"
PY
  then
    ok "T12 S_ISREG: symlink .java skipped, only regular BReal.java counted"
  else
    no "T12 S_ISREG: JSON validation failed"
  fi
else
  no "T12 S_ISREG: expected exit 0, got $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: unreadable .java → status:failed + exit 1
#      chmod 000 the file before running the tool; restore after.
# ---------------------------------------------------------------------------
_unreadable_file="$FIXTURES/unreadable-tree/BUnreadable.java"
chmod 000 "$_unreadable_file" 2>/dev/null
_t13_exit=0
"$SUT" "$FIXTURES/unreadable-tree" --output "$ROOT/t13.json" 2>/dev/null \
  || _t13_exit=$?
chmod 644 "$_unreadable_file" 2>/dev/null  # restore regardless
if [ "$_t13_exit" -eq 1 ]; then
  if python3 - "$ROOT/t13.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected status:failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "expected non-empty errors list"
PY
  then
    ok "T13 unreadable file: exit 1 + status:failed + errors non-empty"
  else
    no "T13 unreadable file: exit 1 but JSON validation failed"
  fi
else
  no "T13 unreadable file: expected exit 1, got $_t13_exit (running as root?)"
fi

# ---------------------------------------------------------------------------
# T14: containment — symlink subdirectory pointing outside root is pruned
#      Creates a symlink dir inside containment-tree pointing to slot-tree.
#      With followlinks=False and the containment check, no slots from slot-tree appear.
# ---------------------------------------------------------------------------
_cont_dir="$ROOT/containment-tree"
mkdir -p "$_cont_dir"
ln -sf "$FIXTURES/slot-tree" "$_cont_dir/escaped" 2>/dev/null || true
_t14_exit=0
"$SUT" "$_cont_dir" --output "$ROOT/t14.json" 2>/dev/null \
  || _t14_exit=$?
if [ "$_t14_exit" -eq 0 ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['slots'] == [], \
    f"containment breach: slots from symlink dir appeared: {d['slots']}"
assert d['scanned'] == 0, \
    f"containment breach: scanned={d['scanned']}, expected 0"
PY
  then
    ok "T14 containment: symlink subdir pruned, no slots from outside root"
  else
    no "T14 containment: JSON validation failed"
  fi
else
  no "T14 containment: expected exit 0, got $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: per-file byte cap visible — patched SUT with _MAX_FILE_BYTES=100;
#      file >100 bytes → files_byte_capped>0 in JSON (D-1 fix)
#      RED before fix: files_byte_capped key absent or zero.
#      GREEN after fix: files_byte_capped is 1 (one file exceeded the cap).
# ---------------------------------------------------------------------------
_t15_sut_dir="$(cd "$(dirname "$SUT")" && pwd)"
_t15_orig_py="$_t15_sut_dir/module_find.py"
_t15_patchdir="$(mktemp -d)"
_t15_work="$(mktemp -d)"
cp "$_t15_orig_py" "$_t15_patchdir/module_find.py"
sed -i 's/_MAX_FILE_BYTES = 2 \* 1024 \* 1024/_MAX_FILE_BYTES = 100/' \
  "$_t15_patchdir/module_find.py"
python3 -c "
content = '@NiagaraProperty(name=\"cap\", type=\"boolean\")\npublic class BCap {}\n' + ' ' * 200
open('${_t15_work}/BCap.java', 'w').write(content)
" 2>/dev/null
_t15_exit=0
python3 "$_t15_patchdir/module_find.py" "$_t15_work" --output "$ROOT/t15.json" 2>/dev/null \
  || _t15_exit=$?
rm -rf "$_t15_patchdir" "$_t15_work"
if [ "$_t15_exit" -eq 0 ]; then
  if python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
cap_count = d.get('files_byte_capped')
assert cap_count is not None and cap_count > 0, \
    f"files_byte_capped must be >0 when file exceeds cap; got {cap_count!r}"
PY
  then
    ok "T15 byte cap visible: files_byte_capped>0 when file exceeds 2-MiB cap"
  else
    no "T15 byte cap visible: files_byte_capped not present or zero (D-1 not implemented?)"
  fi
else
  no "T15 byte cap visible: expected exit 0, got $_t15_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: module-find mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/module_find.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  module_find.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
MUTDIR="$(mktemp -d)"

# --- M1: Remove install-root symlink guard ---
# Mutation: S_ISLNK → S_ISBLK so symlink root is not rejected.
# Step 2 uses os.path.isdir() which follows symlinks, so the dir check passes.
# Expected: symlink root exits 0 instead of 2 → DETECTED.
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if _stat\.S_ISLNK(lstat_result\.st_mode):/if _stat.S_ISBLK(lstat_result.st_mode):  # MUTANT-M1/' \
  "$MUTDIR/module_find.py"
if ! python3 -m py_compile "$MUTDIR/module_find.py" 2>/dev/null; then
  mut_no "M1 symlink guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/module_find.py"; then
  mut_no "M1 symlink guard: sed had no effect (pattern not found)"
else
  _m1_exit=0
  python3 "$MUTDIR/module_find.py" \
    "$ROOT/sym-tree" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 symlink guard removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 symlink guard: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Suppress slot name extraction (slot key set to fixed string) ---
# Mutation: "slot": nm.group(1) → "slot": "MUTANT-M2"
# Expected: extracted slot names are wrong → T6 exact name check fails → DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/"slot": nm\.group(1),/"slot": "MUTANT-M2",  # MUTANT-M2/' \
  "$MUTDIR/module_find.py"
if ! python3 -m py_compile "$MUTDIR/module_find.py" 2>/dev/null; then
  mut_no "M2 slot name mutated: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/module_find.py"; then
  mut_no "M2 slot name mutated: sed had no effect"
else
  _m2_exit=0
  python3 "$MUTDIR/module_find.py" \
    "$FIXTURES/slot-tree" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  _m2_setpoint=""
  if [ -f "$ROOT/m2.json" ]; then
    _m2_setpoint="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m2.json')); names={s['slot'] for s in d.get('slots',[])}; print('correct' if 'setpoint' in names else 'wrong')" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m2_setpoint" = "wrong" ]; then
    mut_ok "M2 slot name mutated: 'setpoint' missing — DETECTED"
  else
    mut_no "M2 slot name mutated: mutation NOT detected (setpoint=$_m2_setpoint)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Break paren-balance continuation loop ---
# Mutation: "while depth > 0" → "while False" so multi-line annotations are not joined.
# Expected: multi-line 'setpoint' annotation (name/type on separate lines) is not
# captured → setpoint missing from slots → T6 DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/while depth > 0 and j < len(lines):/while False and j < len(lines):  # MUTANT-M3/' \
  "$MUTDIR/module_find.py"
if ! python3 -m py_compile "$MUTDIR/module_find.py" 2>/dev/null; then
  mut_no "M3 paren-balance broken: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/module_find.py"; then
  mut_no "M3 paren-balance broken: sed had no effect"
else
  _m3_exit=0
  python3 "$MUTDIR/module_find.py" \
    "$FIXTURES/slot-tree" --output "$ROOT/m3.json" 2>/dev/null || _m3_exit=$?
  _m3_setpoint=""
  if [ -f "$ROOT/m3.json" ]; then
    _m3_setpoint="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m3.json')); names={s['slot'] for s in d.get('slots',[])}; print('found' if 'setpoint' in names else 'missing')" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m3_setpoint" = "missing" ]; then
    mut_ok "M3 paren-balance broken: multi-line 'setpoint' missing — DETECTED"
  else
    mut_no "M3 paren-balance broken: mutation NOT detected (setpoint=$_m3_setpoint)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Break container-form fragment split (only-first-fragment) ---
# Mutation: "return fragments" → "return fragments[:1]" so only the first
# fragment is returned regardless of how many were found.
# Expected: container fixture has alpha+beta; with mutation only alpha is emitted,
# beta missing → T10 assertion fails → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/    return fragments$/    return fragments[:1]  # MUTANT-M4/' \
  "$MUTDIR/module_find.py"
if ! python3 -m py_compile "$MUTDIR/module_find.py" 2>/dev/null; then
  mut_no "M4 only-first-fragment: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/module_find.py"; then
  mut_no "M4 only-first-fragment: sed had no effect (anchor comment not found)"
else
  _m4_exit=0
  python3 "$MUTDIR/module_find.py" \
    "$FIXTURES/container-tree" --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  # Check via @NiagaraActions({...}) container: stopOp must be missing when [:1] truncates.
  # The actions container is accumulated as one buf; _extract_annotation_fragments splits it.
  _m4_stopop=""
  if [ -f "$ROOT/m4.json" ]; then
    _m4_stopop="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m4.json')); names={a['action'] for a in d.get('actions',[])}; print('found' if 'stopOp' in names else 'missing')" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m4_stopop" = "missing" ]; then
    mut_ok "M4 only-first-fragment: container 'stopOp' action missing — DETECTED"
  else
    mut_no "M4 only-first-fragment: mutation NOT detected (stopOp=$_m4_stopop)"
  fi
fi
rm -rf "$MUTDIR"

# --- M5: Suppress byte-cap counter (always False) ---
# Mutation: file_byte_capped = len(raw) == _MAX_FILE_BYTES  →  file_byte_capped = False
# Uses the same patched-cap approach as T15 (cap=100, fixture >100 bytes).
# Expected: files_byte_capped stays 0 even though the file was truncated → T15 logic DETECTS.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/file_byte_capped = len(raw) == _MAX_FILE_BYTES/file_byte_capped = False  # MUTANT-M5/' \
  "$MUTDIR/module_find.py"
if ! python3 -m py_compile "$MUTDIR/module_find.py" 2>/dev/null; then
  mut_no "M5 byte-cap suppressed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/module_find.py"; then
  mut_no "M5 byte-cap suppressed: sed had no effect (pattern not found — D-1 not implemented?)"
else
  _m5_patchdir="$(mktemp -d)"
  _m5_work="$(mktemp -d)"
  cp "$MUTDIR/module_find.py" "$_m5_patchdir/module_find.py"
  sed -i 's/_MAX_FILE_BYTES = 2 \* 1024 \* 1024/_MAX_FILE_BYTES = 100/' \
    "$_m5_patchdir/module_find.py"
  python3 -c "
content = '@NiagaraProperty(name=\"cap\", type=\"boolean\")\npublic class BCap {}\n' + ' ' * 200
open('${_m5_work}/BCap.java', 'w').write(content)
" 2>/dev/null
  _m5_exit=0
  python3 "$_m5_patchdir/module_find.py" "$_m5_work" --output "$ROOT/m5.json" 2>/dev/null \
    || _m5_exit=$?
  _m5_cap=""
  if [ -f "$ROOT/m5.json" ]; then
    _m5_cap="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m5.json')); v=d.get('files_byte_capped',None); print('zero' if v==0 else 'nonzero' if v else 'absent')" \
      2>/dev/null || echo "")"
  fi
  rm -rf "$_m5_patchdir" "$_m5_work"
  if [ "$_m5_cap" = "zero" ]; then
    mut_ok "M5 byte-cap suppressed: files_byte_capped=0 — DETECTED"
  else
    mut_no "M5 byte-cap suppressed: mutation NOT detected (files_byte_capped=$_m5_cap)"
  fi
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
