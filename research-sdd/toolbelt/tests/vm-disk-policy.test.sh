#!/usr/bin/env bash
# vm-disk-policy.test.sh — RED-first contract tests for lib/vm_disk_policy.py (D1)
# Tests EVERY §6 containment rule in the design.
# Written BEFORE lib/vm_disk_policy.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/vm_disk_policy.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, sys
from pathlib import Path
sut = Path(sys.argv[1])
sys.path.insert(0, str(sut.parent)); sys.path.insert(0, str(sut.parent.parent))
sp = importlib.util.spec_from_file_location("vm_disk_policy", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
from gate import GateError
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

# ── Shared test fixtures ──────────────────────────────────────────────────────
RUN_DIR = "/tmp/rsdd-test-run"
SCRATCH_FILE  = f"{RUN_DIR}/scratch.img"
SAMPLE_DRIVE  = "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio"
SCRATCH_DRIVE = f"file={SCRATCH_FILE},snapshot=off,format=raw,if=virtio"
ROOTFS_DRIVE  = "file=/input/rootfs,snapshot=on,format=raw,if=virtio"

# GOOD_ARGV includes the file-scoped scratch bind (INV-2 fix / issue #60).
# The bind must appear AFTER --tmpfs (ordering is load-bearing in bwrap).
GOOD_ARGV = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    "--bind", SCRATCH_FILE, SCRATCH_FILE,
    "--ro-bind", "/store/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample", "--",
    "qemu-system-x86_64",
    "-kernel", "/rsdd/vmlinuz",
    "-m", "256",
    "-smp", "1",
    "-accel", "tcg",
    "-nic", "none",
    "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot",
    "-drive", SAMPLE_DRIVE,
    "-drive", SCRATCH_DRIVE,
    "-drive", ROOTFS_DRIVE,
]

# Sentinel-form GOOD_ARGV (as emitted by build_plan, before executor substitution).
# Used to test plan-time (run_dir=None) acceptance.
_SENTINEL = "/rsdd/scratch.img"
GOOD_ARGV_SENTINEL = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    "--bind", _SENTINEL, _SENTINEL,
    "--ro-bind", "/rsdd/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample", "--",
    "qemu-system-x86_64",
    "-kernel", "/rsdd/vmlinuz",
    "-m", "256",
    "-smp", "1",
    "-accel", "tcg",
    "-nic", "none",
    "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot",
    f"-drive", f"file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
    f"-drive", f"file={_SENTINEL},snapshot=off,format=raw,if=virtio",
    f"-drive", f"file=/input/rootfs,snapshot=on,format=raw,if=virtio",
]

def swap_drive(argv, old_val, new_val):
    """Return a copy of argv with old_val replaced by new_val (in a -drive position)."""
    out = list(argv)
    for i, tok in enumerate(out):
        if tok == "-drive" and i + 1 < len(out) and out[i+1] == old_val:
            out[i+1] = new_val
            return out
    raise ValueError(f"drive value not found: {old_val!r}")

def drop_tok(argv, tok):
    """Return argv with the first occurrence of tok removed (and its following value if applicable)."""
    out = list(argv)
    if tok in out:
        idx = out.index(tok)
        out.pop(idx)
    return out

def drop_pair(argv, flag):
    """Return argv with the flag and its following value removed."""
    out = list(argv)
    if flag in out:
        idx = out.index(flag)
        out.pop(idx)  # flag
        if idx < len(out):
            out.pop(idx)  # value
    return out

def replace_pair(argv, flag, new_val):
    """Return argv with the value after flag replaced by new_val."""
    out = list(argv)
    if flag in out:
        idx = out.index(flag)
        if idx + 1 < len(out):
            out[idx + 1] = new_val
    return out

def add_after(argv, anchor, *tokens):
    """Insert tokens after anchor."""
    out = list(argv)
    idx = out.index(anchor)
    for j, t in enumerate(tokens, 1):
        out.insert(idx + j, t)
    return out

def remove_drive(argv, drive_val):
    """Return a copy of argv with the -drive <drive_val> pair removed (first match)."""
    out = []
    i = 0
    while i < len(argv):
        if argv[i] == "-drive" and i + 1 < len(argv) and argv[i + 1] == drive_val:
            i += 2  # skip this -drive pair
        else:
            out.append(argv[i]); i += 1
    return out

def assert_gate_error(fn, label):
    """Assert fn() raises GateError; nok/ok reporting."""
    try:
        fn()
        nok(label, "expected GateError but no exception raised")
    except GateError as e:
        ok(f"{label}: {e}")
    except Exception as e:
        nok(label, f"unexpected exception {type(e).__name__}: {e}")

def assert_gate_error_msg(fn, label, expected_fragment):
    """Assert fn() raises GateError whose message contains expected_fragment.

    Use this instead of assert_gate_error when the test must verify WHICH rule
    fired, not merely that some rule fired.
    """
    try:
        fn()
        nok(label, "expected GateError but no exception raised")
    except GateError as e:
        msg = str(e)
        if expected_fragment in msg:
            ok(f"{label}: {e}")
        else:
            nok(label, f"GateError raised but message lacked {expected_fragment!r}: {e}")
    except Exception as e:
        nok(label, f"unexpected exception {type(e).__name__}: {e}")

def assert_passes(fn, label):
    """Assert fn() does NOT raise."""
    try:
        fn()
        ok(label)
    except Exception as e:
        nok(label, f"unexpected exception: {e}")

# ── VDP-T7: Well-formed detonate argv → passes cleanly (triangulation anchor) ─
# Write this first so we always confirm the reference point.
assert_passes(
    lambda: m.check_disk_policy(GOOD_ARGV, run_dir=RUN_DIR),
    "VDP-T7: well-formed detonate argv passes check_disk_policy"
)

# ── VDP-T1a: sample drive missing readonly=on → GateError ────────────────────
# Rule §6: Sample disk MUST be readonly=on AND snapshot=off
_t1a_argv = swap_drive(GOOD_ARGV, SAMPLE_DRIVE,
    "file=/input/sample,snapshot=off,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t1a_argv, run_dir=RUN_DIR),
    "VDP-T1a: sample drive without readonly=on → GateError"
)

# ── VDP-T1b: sample drive with snapshot=on and no readonly=on → GateError ────
# Rule §6: sample must NOT be COW-writable (guest can write overlay)
_t1b_argv = swap_drive(GOOD_ARGV, SAMPLE_DRIVE,
    "file=/input/sample,snapshot=on,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t1b_argv, run_dir=RUN_DIR),
    "VDP-T1b: sample drive snapshot=on (no readonly) → GateError"
)

# ── VDP-T2a: scratch drive snapshot=on instead of snapshot=off → GateError ───
# Rule §6: Scratch disk MUST be snapshot=off (writes persist to host file).
# If snapshot=on, scratch is COW → 0 writable-persistent drives ≠ 1 → GateError.
_t2a_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    f"file={RUN_DIR}/scratch.img,snapshot=on,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t2a_argv, run_dir=RUN_DIR),
    "VDP-T2a: scratch drive snapshot=on (not snapshot=off) → GateError"
)

# ── VDP-T2b: scratch path outside run_dir → GateError ────────────────────────
# Rule §6: Scratch file= path must be under the per-run run_dir.
_t2b_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    "file=/tmp/other-dir/scratch.img,snapshot=off,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t2b_argv, run_dir=RUN_DIR),
    "VDP-T2b: scratch path outside run_dir → GateError"
)

# ── VDP-T3a: two writable-persistent drives → GateError ──────────────────────
# Rule §6: Exactly ONE writable-persistent disk (the scratch).
_t3a_argv = add_after(GOOD_ARGV, "-no-reboot",
    "-drive", "file=/tmp/extra/extra.img,snapshot=off,format=raw,if=virtio")
# Now there are two snapshot=off writable drives (scratch + extra) → count=2
assert_gate_error(
    lambda: m.check_disk_policy(_t3a_argv, run_dir=RUN_DIR),
    "VDP-T3a: two writable-persistent drives → GateError"
)

# ── VDP-T3b: rootfs rule ISOLATED — rootfs as sole persistent drive → GateError ─
# Fix 3: drop scratch; rootfs=snapshot=off → 1 persistent drive (count passes);
# rootfs rule fires. Isolation proof: if rootfs rule (lines 184-188) were removed,
# count=1 passes and run_dir=None skips scope check → no error → test would FAIL.
_t3b_argv = remove_drive(GOOD_ARGV, SCRATCH_DRIVE)
_t3b_argv = swap_drive(_t3b_argv, ROOTFS_DRIVE,
    "file=/input/rootfs,snapshot=off,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t3b_argv, run_dir=None),
    "VDP-T3b: rootfs sole persistent (snapshot=off, no readonly) → GateError (rootfs rule isolated)"
)

# ── VDP-T4: format=qcow2 on any drive → GateError ───────────────────────────
# Rule §6: format=raw mandatory on every -drive; qcow2 backing-file = escape vector.
_t4_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    f"file={RUN_DIR}/scratch.img,snapshot=off,format=qcow2,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t4_argv, run_dir=RUN_DIR),
    "VDP-T4: format=qcow2 on any -drive → GateError"
)

# ── VDP-T5: /dev/ rule ISOLATED — /dev/sda as sole persistent drive → GateError ─
# Fix 4: replace scratch with /dev/sda; count=1; run_dir=None skips scope check.
# Isolation proof: if /dev/ check (lines 170-174) were removed → persistent=["/dev/sda"],
# count=1, no scope check → no error → test would FAIL.
_t5_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    "file=/dev/sda,snapshot=off,format=raw,if=virtio")
assert_gate_error(
    lambda: m.check_disk_policy(_t5_argv, run_dir=None),
    "VDP-T5: -drive file=/dev/sda as sole persistent → GateError (/dev/ rule isolated)"
)

# ── VDP-T6a: -net present → GateError ───────────────────────────────────────
# Rule §6: Retain V1b belt: reject -net/-netdev.
_t6a_argv = add_after(GOOD_ARGV, "-nodefaults", "-net", "user")
assert_gate_error(
    lambda: m.check_disk_policy(_t6a_argv, run_dir=RUN_DIR),
    "VDP-T6a: -net present → GateError"
)

# ── VDP-T6b: -netdev present → GateError ─────────────────────────────────────
_t6b_argv = add_after(GOOD_ARGV, "-nodefaults", "-netdev", "user,id=n0")
assert_gate_error(
    lambda: m.check_disk_policy(_t6b_argv, run_dir=RUN_DIR),
    "VDP-T6b: -netdev present → GateError"
)

# ── VDP-T6c: -enable-kvm present → GateError ─────────────────────────────────
# Rule §6: reject -enable-kvm/-accel kvm (KVM = host kernel virt extensions).
_t6c_argv = add_after(GOOD_ARGV, "-nodefaults", "-enable-kvm")
assert_gate_error(
    lambda: m.check_disk_policy(_t6c_argv, run_dir=RUN_DIR),
    "VDP-T6c: -enable-kvm present → GateError"
)

# ── VDP-T6d: -virtfs present → GateError ─────────────────────────────────────
# Rule §6: reject -virtfs/-fsdev/9p (host-FS sharing vectors).
_t6d_argv = add_after(GOOD_ARGV, "-nodefaults", "-virtfs", "local,path=/host,mount_tag=host")
assert_gate_error(
    lambda: m.check_disk_policy(_t6d_argv, run_dir=RUN_DIR),
    "VDP-T6d: -virtfs present → GateError"
)

# ── VDP-T6e: -device vfio-pci → GateError ────────────────────────────────────
# Rule §6: reject -device vfio*/virtio-9p* (host passthrough/9p).
_t6e_argv = add_after(GOOD_ARGV, "-nodefaults", "-device", "vfio-pci,host=01:00.0")
assert_gate_error(
    lambda: m.check_disk_policy(_t6e_argv, run_dir=RUN_DIR),
    "VDP-T6e: -device vfio-pci → GateError (passthrough refused)"
)

# ── VDP-T6f: -accel kvm instead of tcg → GateError ──────────────────────────
# Rule §6: require -accel tcg; reject -accel kvm.
_t6f_argv = replace_pair(GOOD_ARGV, "-accel", "kvm")
assert_gate_error(
    lambda: m.check_disk_policy(_t6f_argv, run_dir=RUN_DIR),
    "VDP-T6f: -accel kvm (not tcg) → GateError"
)

# ── VDP-T6g: -nic missing → GateError ────────────────────────────────────────
# Rule §6: require -nic none (belt-and-suspenders with --unshare-net).
_t6g_argv = drop_pair(GOOD_ARGV, "-nic")
assert_gate_error(
    lambda: m.check_disk_policy(_t6g_argv, run_dir=RUN_DIR),
    "VDP-T6g: -nic missing → GateError"
)

# ── VDP-T6h: -smp 4 (not 1) → GateError ─────────────────────────────────────
# Rule §6: require -smp 1 (bound vCPUs to 1).
_t6h_argv = replace_pair(GOOD_ARGV, "-smp", "4")
assert_gate_error(
    lambda: m.check_disk_policy(_t6h_argv, run_dir=RUN_DIR),
    "VDP-T6h: -smp 4 (not 1) → GateError"
)

# ── VDP-T6i: -nodefaults missing → GateError ─────────────────────────────────
# Rule §6: require -nodefaults (suppress default devices).
_t6i_argv = drop_tok(GOOD_ARGV, "-nodefaults")
assert_gate_error(
    lambda: m.check_disk_policy(_t6i_argv, run_dir=RUN_DIR),
    "VDP-T6i: -nodefaults missing → GateError"
)

# ── VDP-T6j: -sandbox missing → GateError ────────────────────────────────────
# Rule §6: require -sandbox on,... (qemu seccomp filter).
_t6j_argv = drop_pair(GOOD_ARGV, "-sandbox")
assert_gate_error(
    lambda: m.check_disk_policy(_t6j_argv, run_dir=RUN_DIR),
    "VDP-T6j: -sandbox missing → GateError"
)

# ── VDP-T6k: --unshare-net missing → GateError ───────────────────────────────
# Rule §6: require --unshare-net (bwrap network namespace isolation).
_t6k_argv = drop_tok(GOOD_ARGV, "--unshare-net")
assert_gate_error(
    lambda: m.check_disk_policy(_t6k_argv, run_dir=RUN_DIR),
    "VDP-T6k: --unshare-net missing → GateError"
)

# ── VDP-T6l: -sandbox value allows escalation → GateError ────────────────────
# Rule §6: -sandbox must start with "on" and must NOT contain "=allow".
_t6l_argv = replace_pair(GOOD_ARGV, "-sandbox",
    "on,obsolete=allow,elevateprivileges=deny,spawn=deny,resourcecontrol=deny")
assert_gate_error(
    lambda: m.check_disk_policy(_t6l_argv, run_dir=RUN_DIR),
    "VDP-T6l: -sandbox with =allow → GateError"
)

# ── VDP-T8: run_dir=None skips scope check (plan-time use) ───────────────────
# Scratch at /rsdd/scratch.img (not under RUN_DIR) → passes when run_dir=None.
# GOOD_ARGV_SENTINEL has both the bwrap bind and the -drive spec using the same
# sentinel path (/rsdd/scratch.img), so R-BIND-RW is satisfied and the scope
# check (run_dir=None) is the only gate that could reject it — it must not.
_t8_argv = list(GOOD_ARGV_SENTINEL)
assert_passes(
    lambda: m.check_disk_policy(_t8_argv),  # no run_dir → skip scope check
    "VDP-T8: run_dir=None skips scratch scope check (plan-time validation)"
)

# ── VDP-T9: -drive spec missing file= key → GateError (fail-closed guard) ───────
# Fix 2: file= absent silently defaults to "" → fail-OPEN on old code (no error at plan-time).
# Guard: reject any -drive whose file= key is missing or empty before classification.
# RED: current code passes (file="" treated as valid persistent path); guard makes it GateError.
_t9_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    "snapshot=off,format=raw,if=virtio")  # no file= key
assert_gate_error(
    lambda: m.check_disk_policy(_t9_argv, run_dir=None),
    "VDP-T9: -drive missing file= key → GateError (fail-closed)"
)

# ===========================================================================
# Slice 2 — R-REACH / R-BIND-RW / R-BWRAP-DENY (INV-2 / issue #60)
# All cases below are RED until the three rules are implemented in
# lib/vm_disk_policy.py.  GREEN cases use assert_passes.
# ===========================================================================

# ── RED-BIND-ABSENT: no --bind at all → GateError (R-BIND-RW) ────────────
# When the argv contains no --bind op, R-BIND-RW fires at step 5 because the
# mandatory scratch file bind is missing (0 rw binds found, expected exactly 1).
# This tests R-BIND-RW, NOT R-REACH.
#
# Note: the scratch path (/tmp/rsdd-test-run/scratch.img) is a SIBLING of the
# tmpfs dest (/tmp/rsdd), not a child, so --tmpfs /tmp/rsdd would NOT mask it
# regardless of ordering.  R-REACH (step 6) is never reached here because
# R-BIND-RW (step 5) fires first.  For ordering-sensitive R-REACH coverage see
# RED-REACH-ORDER below, which exercises a bind-before-tmpfs scenario where the
# scratch path IS a child of the tmpfs dest and R-BIND-RW passes.
_bind_absent_argv = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    # NO --bind here → R-BIND-RW fires (0 rw binds, expected 1)
    "--ro-bind", "/rsdd/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample", "--",
    "qemu-system-x86_64", "-m", "256", "-smp", "1", "-accel", "tcg",
    "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot",
    "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
    "-drive", f"file={RUN_DIR}/scratch.img,snapshot=off,format=raw,if=virtio",
    "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_bind_absent_argv, run_dir=RUN_DIR),
    "RED-BIND-ABSENT: no --bind present → GateError (R-BIND-RW: 0 rw binds)",
    "R-BIND-RW"
)

# ── RED-REACH-ORDER: bind placed BEFORE --tmpfs → GateError ───────────────
# bwrap applies ops in order; a bind before --tmpfs is silently re-masked.
# R-REACH must model ordering, not set membership.
#
# IMPORTANT: the scratch path must be a CHILD of the tmpfs path (/tmp/rsdd)
# for ordering to matter.  Using a sibling path (like /tmp/rsdd-test-run) would
# not be masked by --tmpfs /tmp/rsdd regardless of ordering.  We use a
# dedicated run dir under /tmp/rsdd so the masking relationship is real.
_ORDER_RUN_DIR   = "/tmp/rsdd/rsdd-testrun"   # child of tmpfs dest
_ORDER_SCRATCH   = f"{_ORDER_RUN_DIR}/scratch.img"
_ORDER_SCRATCH_D = f"file={_ORDER_SCRATCH},snapshot=off,format=raw,if=virtio"
_reach_order_argv = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--bind", _ORDER_SCRATCH, _ORDER_SCRATCH,  # bind BEFORE tmpfs — re-masked
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    "--ro-bind", "/rsdd/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample", "--",
    "qemu-system-x86_64", "-m", "256", "-smp", "1", "-accel", "tcg",
    "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot",
    "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
    "-drive", _ORDER_SCRATCH_D,
    "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_reach_order_argv, run_dir=_ORDER_RUN_DIR),
    "RED-REACH-ORDER: bind before --tmpfs → GateError (R-REACH ordering-aware)",
    "R-REACH"
)

# ── GREEN-REACH-OK: bind placed AFTER --tmpfs → passes cleanly ────────────
# Correct ordering: --tmpfs first, then --bind scratch → scratch reachable.
assert_passes(
    lambda: m.check_disk_policy(GOOD_ARGV, run_dir=RUN_DIR),
    "GREEN-REACH-OK: bind after --tmpfs → check_disk_policy passes (R-REACH)"
)

# ── RED-REACH-SAMPLE-UNBOUND: sample ro-bind DEST mistyped → GateError ───
# R-REACH must cover every -drive file= slot, not only the scratch drive.
# Without the G2 fix (iterating all_drive_paths), this argv PASSES because
# only the scratch path is verified.  With the fix, R-REACH walks /input/sample
# and finds no bind covering it (DEST was renamed to /input/sampleX) → GateError.
_sample_unbound_argv = list(GOOD_ARGV)
_sub_idx = _sample_unbound_argv.index("/input/sample")  # ro-bind DEST token
_sample_unbound_argv[_sub_idx] = "/input/sampleX"       # mismatch; drive still says /input/sample
assert_gate_error_msg(
    lambda: m.check_disk_policy(_sample_unbound_argv, run_dir=RUN_DIR),
    "RED-REACH-SAMPLE-UNBOUND: sample ro-bind DEST mistyped → GateError (R-REACH all drives)",
    "R-REACH"
)

# ── RED-BIND-DIR: --bind <run_dir> <run_dir> (directory, not file) → GateError ─
# The directory bind is rejected: guest writes land in host run_dir, swept into
# receipt outputs[]. Only the specific scratch file may be bound read-write.
_bind_dir_argv = list(GOOD_ARGV)
i_src = _bind_dir_argv.index(SCRATCH_FILE)
_bind_dir_argv[i_src] = RUN_DIR       # SRC ← dir
_bind_dir_argv[i_src + 1] = RUN_DIR   # DEST ← dir
assert_gate_error_msg(
    lambda: m.check_disk_policy(_bind_dir_argv, run_dir=RUN_DIR),
    "RED-BIND-DIR: --bind <run_dir> <run_dir> → GateError (R-BIND-RW: must be scratch file)",
    "file-scoped"
)

# ── RED-BIND-NONIDENTITY: SRC != DEST → GateError ─────────────────────────
# R-BIND-RW requires SRC == DEST (identity map) so the bind cannot redirect.
_nonid_argv = list(GOOD_ARGV)
i_src2 = _nonid_argv.index(SCRATCH_FILE)
_nonid_argv[i_src2] = "/etc/passwd"   # SRC != DEST
assert_gate_error_msg(
    lambda: m.check_disk_policy(_nonid_argv, run_dir=RUN_DIR),
    "RED-BIND-NONIDENTITY: --bind SRC != DEST → GateError (R-BIND-RW identity required)",
    "identity-mapped"
)

# ── RED-BIND-EXTRA-RW: two --bind ops → GateError ─────────────────────────
# R-BIND-RW: at most one read-write bind permitted.
# The extra bind must be inserted BEFORE "--" so it is in the bwrap prefix
# (tokens appended after "--" land in the qemu inner command and are not
# scanned by R-BIND-RW, which operates on the bwrap prefix only).
_extra_bind_argv = list(GOOD_ARGV)
_eb_sep = _extra_bind_argv.index("--")
_extra_bind_argv[_eb_sep:_eb_sep] = ["--bind", f"{RUN_DIR}/extra.img", f"{RUN_DIR}/extra.img"]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_extra_bind_argv, run_dir=RUN_DIR),
    "RED-BIND-EXTRA-RW: two --bind ops → GateError (R-BIND-RW at most one rw bind)",
    "exactly 1 read-write"
)

# ── RED-BWRAP-DENY: --dev-bind, --ro-bind-try, --overlay each → GateError ──
# R-BWRAP-DENY: these families fail-open on missing source → silent F5 repeat.
# Each forbidden op must be inserted BEFORE "--" so it is in the bwrap prefix
# (tokens appended after "--" land in the qemu inner command and are not
# scanned by R-BWRAP-DENY, which operates on the bwrap prefix only).
for _deny_flag, _deny_args in [
    ("--dev-bind",    ["--dev-bind", "/dev/null", "/dev/null"]),
    ("--ro-bind-try", ["--ro-bind-try", "/nope", "/nope"]),
    ("--overlay",     ["--overlay", "/a", "/b", "/c"]),
    ("--bind-try",    ["--bind-try", "/nope", "/nope"]),
]:
    _deny_argv = list(GOOD_ARGV)
    _deny_sep = _deny_argv.index("--")
    _deny_argv[_deny_sep:_deny_sep] = _deny_args
    assert_gate_error_msg(
        lambda _a=_deny_argv, _f=_deny_flag:
            m.check_disk_policy(_a, run_dir=RUN_DIR),
        f"RED-BWRAP-DENY({_deny_flag}): forbidden bwrap op → GateError (R-BWRAP-DENY)",
        "R-BWRAP-DENY"
    )

# ── GREEN-SUBST-INVARIANT: sentinel form and substituted form both pass ────
# The invariant must hold at plan time (run_dir=None, sentinel paths) AND after
# executor substitution (run_dir=RUN_DIR, real paths).  This confirms the
# checker is substitution-invariant: plan and exec cannot drift.
assert_passes(
    lambda: m.check_disk_policy(GOOD_ARGV_SENTINEL, run_dir=None),
    "GREEN-SUBST-INVARIANT (sentinel, run_dir=None): plan-time argv passes R-REACH+R-BIND-RW"
)
assert_passes(
    lambda: m.check_disk_policy(GOOD_ARGV, run_dir=RUN_DIR),
    "GREEN-SUBST-INVARIANT (substituted, run_dir set): post-substitution argv passes R-REACH+R-BIND-RW"
)

# ── PARITY: trace rejects everything detonate rejects (shared checker) ────
# The vm_disk_policy checker is the same module for both executors.
# Re-run every new RED case through check_disk_policy to confirm parity.
# By construction: since there is ONE checker, parity holds automatically.
# These assertions document and enforce that assumption.
assert_gate_error_msg(
    lambda: m.check_disk_policy(_bind_absent_argv, run_dir=RUN_DIR),
    "PARITY-BIND-ABSENT: trace also rejects missing --bind (shared checker)",
    "R-BIND-RW"
)
assert_gate_error_msg(
    lambda: m.check_disk_policy(_reach_order_argv, run_dir=_ORDER_RUN_DIR),
    "PARITY-REACH-ORDER: trace also rejects wrong-order bind (shared checker)",
    "R-REACH"
)
assert_gate_error_msg(
    lambda: m.check_disk_policy(_bind_dir_argv, run_dir=RUN_DIR),
    "PARITY-BIND-DIR: trace also rejects directory bind (shared checker)",
    "file-scoped"
)
assert_gate_error_msg(
    lambda: m.check_disk_policy(_extra_bind_argv, run_dir=RUN_DIR),
    "PARITY-BIND-EXTRA-RW: trace also rejects two rw binds (shared checker)",
    "exactly 1 read-write"
)
assert_gate_error_msg(
    lambda: m.check_disk_policy(_nonid_argv, run_dir=RUN_DIR),
    "PARITY-BIND-NONIDENTITY: trace also rejects non-identity bind (shared checker)",
    "identity-mapped"
)

# ===========================================================================
# Slice 3 — F2 / issue #61: block-device allowlist + bwrap teeth + scope-all
# All cases below are RED until the three rules are implemented in
# lib/vm_disk_policy.py.
# ===========================================================================

# ── VDP-T10a: --cap-drop missing → GateError (bwrap teeth / R-CAP-DROP) ──────
# bwrap must drop ALL capabilities; a prefix without --cap-drop lets the guest
# process retain host capabilities inherited through the bwrap invocation.
_t10a_argv = drop_pair(GOOD_ARGV, "--cap-drop")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10a_argv, run_dir=RUN_DIR),
    "VDP-T10a: --cap-drop missing → GateError (bwrap teeth)",
    "--cap-drop"
)

# ── VDP-T10b: --cap-drop NET_RAW (wrong value) → GateError (must be ALL) ──────
# Partial capability drop is not sufficient; the checker requires --cap-drop ALL.
_t10b_argv = replace_pair(GOOD_ARGV, "--cap-drop", "NET_RAW")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10b_argv, run_dir=RUN_DIR),
    "VDP-T10b: --cap-drop NET_RAW instead of ALL → GateError (value check)",
    "--cap-drop"
)

# ── VDP-T10c: --unshare-pid missing → GateError (bwrap teeth / R-UNSHARE-PID) ─
# PID namespace isolation prevents the guest from seeing or signalling host
# processes; without it the bwrap sandbox is incomplete.
_t10c_argv = drop_tok(GOOD_ARGV, "--unshare-pid")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10c_argv, run_dir=RUN_DIR),
    "VDP-T10c: --unshare-pid missing → GateError (bwrap teeth)",
    "--unshare-pid"
)

# ── VDP-T10d: --tmpfs missing → GateError (bwrap teeth / R-TMPFS) ─────────────
# The tmpfs mount scrubs the writable temp tree; omitting it lets the guest
# observe and modify the host's /tmp/rsdd subtree.
_t10d_argv = drop_pair(GOOD_ARGV, "--tmpfs")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10d_argv, run_dir=RUN_DIR),
    "VDP-T10d: --tmpfs missing → GateError (bwrap teeth)",
    "--tmpfs"
)

# ── VDP-T10e: -- separator missing → GateError (bwrap teeth / R-SEP) ──────────
# Without the -- separator the checker cannot reliably split bwrap prefix from
# the qemu inner command; the required-flag check must enforce its presence.
_t10e_argv = drop_tok(GOOD_ARGV, "--")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10e_argv, run_dir=RUN_DIR),
    "VDP-T10e: -- separator missing → GateError (bwrap teeth)",
    "'--'"
)

# ── VDP-T11: inner-flag allowlist — flags that bypass -drive containment ────────
# Only flags in _QEMU_INNER_ALLOWED may appear in the qemu-inner slice.
# Block-device introducers (-hda, -mtdblock, -blockdev, …) are flag-shaped but
# absent from the closed set and are therefore rejected by the allowlist catch-all.
# Mutation obligation (B3): removing any entry from _QEMU_INNER_ALLOWED must turn
# VDP-T7 (well-formed argv) RED — documented here, verified by reviewer mutation.
for _bd_flag, _bd_args in [
    ("-hda",      ["-hda",      "/tmp/rsdd-test-run/extra.img"]),
    ("-hdb",      ["-hdb",      "/tmp/rsdd-test-run/extra.img"]),
    ("-hdc",      ["-hdc",      "/tmp/rsdd-test-run/extra.img"]),
    ("-hdd",      ["-hdd",      "/tmp/rsdd-test-run/extra.img"]),
    ("-cdrom",    ["-cdrom",    "/tmp/rsdd-test-run/disk.iso"]),
    ("-blockdev", ["-blockdev", "node-name=drive0,driver=file,filename=/tmp/rsdd-test-run/x.raw"]),
    ("-pflash",   ["-pflash",   "/tmp/rsdd-test-run/pflash.bin"]),
    ("-fda",      ["-fda",      "/tmp/rsdd-test-run/floppy.img"]),
    ("-fdb",      ["-fdb",      "/tmp/rsdd-test-run/floppy2.img"]),
    ("-sd",       ["-sd",       "/tmp/rsdd-test-run/sd.img"]),
    # Non-enumerated flags — closed-set proof (B1): previously would have bypassed
    # the denylist; the allowlist rejects them by construction (R-INNER-ALLOWLIST).
    ("-mtdblock", ["-mtdblock", "/tmp/rsdd-test-run/mtd.img"]),
    ("-nvme",     ["-nvme",     "id=nvme0,file=/tmp/rsdd-test-run/nvme.raw"]),
]:
    _bd_argv = list(GOOD_ARGV)
    _bd_argv.extend(_bd_args)   # append after qemu inner command tokens
    assert_gate_error_msg(
        lambda _a=_bd_argv, _f=_bd_flag:
            m.check_disk_policy(_a, run_dir=RUN_DIR),
        f"VDP-T11({_bd_flag}): unlisted inner flag → GateError (R-INNER-ALLOWLIST)",
        "R-INNER-ALLOWLIST"
    )

# ── VDP-T11-pos: sanctioned inner flags still pass (allowlist boundary guard) ──
# -nographic and -no-reboot are in _QEMU_INNER_ALLOWED; they must not be rejected.
# Guards against an over-broad allowlist accidentally removing a needed entry.
assert_passes(
    lambda: m.check_disk_policy(GOOD_ARGV, run_dir=RUN_DIR),
    "VDP-T11-pos: -nographic and -no-reboot in inner slice still pass (allowlist boundary)"
)

# ── VDP-T12: scope-check ALL drive file= paths (R-SCOPE-ALL) ──────────────────
# Currently only the scratch drive is scope-checked against run_dir.  A readonly
# drive whose file= path is a host path outside run_dir (not a /input/ sandbox
# path) must also be rejected.
#
# Setup: add a ro-bind so R-REACH passes, then add a readonly drive whose path
# is outside run_dir.  The OLD code ignores this path; the NEW code rejects it.
_ROGUE_HOST_PATH = "/mnt/external/rogue.raw"
_t12_argv = list(GOOD_ARGV)
_t12_sep = _t12_argv.index("--")
# Insert ro-bind BEFORE -- so it lands in the bwrap prefix (R-REACH scans there)
_t12_argv[_t12_sep:_t12_sep] = ["--ro-bind", _ROGUE_HOST_PATH, _ROGUE_HOST_PATH]
# Append readonly drive into the qemu inner command (after --)
_t12_argv += ["-drive", f"file={_ROGUE_HOST_PATH},readonly=on,format=raw,if=virtio"]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t12_argv, run_dir=RUN_DIR),
    "VDP-T12: readonly drive with host path outside run_dir → GateError (R-SCOPE-ALL)",
    "R-SCOPE-ALL"
)

# ===========================================================================
# Slice A — D1: slice-scoped required flags (relocation mutations)
# All relocation cases are RED against the current set(argv) code because
# the full-argv set contains the relocated token even though bwrap never
# receives it.  GREEN after the partition into bwrap_prefix / inner checks.
# ===========================================================================

# ── VDP-T10c-reloc: --unshare-pid relocated to inner slice → GateError ─────────
# Mutation-by-relocation: token is removed from the bwrap prefix and reinserted
# after --. The full-argv set still contains it, so set(argv) code passes (RED).
# "bwrap prefix missing" is unique to the bwrap-required error message and absent
# from the R-INNER-ALLOWLIST backstop, so this fragment proves slice-scoping bites.
_t10c_reloc = drop_tok(GOOD_ARGV, "--unshare-pid")
_sep_r = _t10c_reloc.index("--")
_t10c_reloc.insert(_sep_r + 1, "--unshare-pid")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10c_reloc, run_dir=RUN_DIR),
    "VDP-T10c-reloc: --unshare-pid relocated to inner slice → GateError (D1 slice-scoped)",
    "bwrap prefix missing"
)

# ── VDP-T10a-reloc: --cap-drop ALL relocated to inner slice → GateError ─────────
# "bwrap prefix missing" is unique to the bwrap-required message, proving the
# slice-scoped check fires rather than the R-INNER-ALLOWLIST backstop.
_t10a_reloc = drop_pair(GOOD_ARGV, "--cap-drop")
_sep_r = _t10a_reloc.index("--")
_t10a_reloc[_sep_r + 1:_sep_r + 1] = ["--cap-drop", "ALL"]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10a_reloc, run_dir=RUN_DIR),
    "VDP-T10a-reloc: --cap-drop ALL relocated to inner slice → GateError (D1 slice-scoped)",
    "bwrap prefix missing"
)

# ── VDP-T10d-reloc: --tmpfs /tmp/rsdd relocated to inner slice → GateError ──────
# "bwrap prefix missing" is unique to the bwrap-required message, proving the
# slice-scoped check fires rather than the R-INNER-ALLOWLIST backstop.
_t10d_reloc = drop_pair(GOOD_ARGV, "--tmpfs")
_sep_r = _t10d_reloc.index("--")
_t10d_reloc[_sep_r + 1:_sep_r + 1] = ["--tmpfs", "/tmp/rsdd"]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t10d_reloc, run_dir=RUN_DIR),
    "VDP-T10d-reloc: --tmpfs relocated to inner slice → GateError (D1 slice-scoped)",
    "bwrap prefix missing"
)

# ── VDP-T13: -sandbox dropped from inner slice → GateError (inner-required) ─────
# Fragment "qemu-inner" is unique to the inner-required error message, proving
# the rule specifically targets the qemu-inner slice, not the full-argv set.
_t13_argv = drop_pair(GOOD_ARGV, "-sandbox")
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t13_argv, run_dir=RUN_DIR),
    "VDP-T13: -sandbox dropped from inner slice → GateError (inner-required rule)",
    "qemu-inner"
)

# ── VDP-T13-reloc: -smp 1 relocated to bwrap prefix → GateError (inner-required) ─
# Relocation: token present in full-argv set so set(argv) code passes (RED).
# After fix: set(inner) lacks -smp → inner-required check fires. Fragment "qemu-inner".
_t13_reloc = drop_pair(GOOD_ARGV, "-smp")
_sep_r = _t13_reloc.index("--")
_t13_reloc[_sep_r:_sep_r] = ["-smp", "1"]  # insert before --
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t13_reloc, run_dir=RUN_DIR),
    "VDP-T13-reloc: -smp 1 relocated to bwrap prefix → GateError (inner-required rule)",
    "qemu-inner"
)

# ===========================================================================
# Slice C — D3: path-safe exemption + scratch always scoped
# Both cases are RED against the current startswith("/input/") exemption code.
# GREEN after the fix: unconditional scratch scope + normpath-based exemption.
# ===========================================================================

# ── VDP-T14: writable scratch at /input/scratch.img → GateError (R-SCOPE-ALL) ──
# Regression case: the /input/ exemption introduced in #61 suppressed the
# run_dir scope check for scratch even when it is writable-persistent.
# The scratch must always be scope-checked regardless of its path prefix.
_INPUT_SCRATCH = "/input/scratch.img"
_t14_argv = [tok.replace(SCRATCH_FILE, _INPUT_SCRATCH) for tok in GOOD_ARGV]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t14_argv, run_dir=RUN_DIR),
    "VDP-T14: writable scratch at /input/scratch.img → GateError (R-SCOPE-ALL regression)",
    "R-SCOPE-ALL"
)

# ── VDP-T15: traversal path /input/../etc/shadow → GateError (R-SCOPE-ALL) ──────
# The raw startswith("/input/") check exempts /input/../etc/shadow because the
# string prefix matches, but posixpath.normpath resolves it to /etc/shadow which
# is not a recognized sandbox-internal DEST.
_TRAVERSAL_GUEST = "/input/../etc/shadow"
_t15_argv = list(GOOD_ARGV)
_t15_sep = _t15_argv.index("--")
_t15_argv[_t15_sep:_t15_sep] = ["--ro-bind", "/etc/shadow", _TRAVERSAL_GUEST]
_t15_argv += ["-drive", f"file={_TRAVERSAL_GUEST},readonly=on,format=raw,if=virtio"]
assert_gate_error_msg(
    lambda: m.check_disk_policy(_t15_argv, run_dir=RUN_DIR),
    "VDP-T15: traversal /input/../etc/shadow bypasses /input/ prefix → GateError (R-SCOPE-ALL)",
    "R-SCOPE-ALL"
)

# ── VDP-REACH-* — R-REACH ext.: kernel/qbin reachability (gaps 1/3/4) ────────
_RT_DEST = "/rsdd/rt"
_RT_SRC  = "/opt/rsdd/rt"

# Shared rt-tree argv: rt bind covers /rsdd/rt; drives are standard.
_rt_argv_base = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    "--bind", SCRATCH_FILE, SCRATCH_FILE,
    "--ro-bind", _RT_SRC, _RT_DEST,
    "--ro-bind", "/store/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample", "--",
    f"{_RT_DEST}/bin/qemu-system-x86_64",
    "-kernel", f"{_RT_DEST}/vmlinuz",
    "-m", "256", "-smp", "1", "-accel", "tcg", "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot",
    "-drive", SAMPLE_DRIVE, "-drive", SCRATCH_DRIVE, "-drive", ROOTFS_DRIVE,
]

# ── VDP-REACH-KERNEL-UNBOUND (RED): kernel at uncovered path → GateError ─────
_reach_kern_argv = list(_rt_argv_base)
_reach_kern_argv[_reach_kern_argv.index("-kernel") + 1] = "/rsdd/other/vmlinuz"
assert_gate_error_msg(
    lambda: m.check_disk_policy(_reach_kern_argv, run_dir=RUN_DIR),
    "VDP-REACH-KERNEL-UNBOUND: kernel outside rt-bind dest + rt bind present → GateError (R-REACH ext.)",
    "R-REACH"
)
# ── VDP-REACH-QBIN-UNBOUND (RED): absolute qbin outside rt bind → GateError ──
_reach_qbin_argv = list(_rt_argv_base)
_sep2 = _reach_qbin_argv.index("--")
_reach_qbin_argv[_sep2 + 1] = "/rsdd/other/bin/qemu-system-x86_64"
assert_gate_error_msg(
    lambda: m.check_disk_policy(_reach_qbin_argv, run_dir=RUN_DIR),
    "VDP-REACH-QBIN-UNBOUND: absolute qbin outside rt-bind dest → GateError (R-REACH ext.)",
    "R-REACH"
)
# ── VDP-REACH-RT-OK (GREEN): both kernel and qbin covered by rt bind → passes ─
assert_passes(
    lambda: m.check_disk_policy(list(_rt_argv_base), run_dir=RUN_DIR),
    "VDP-REACH-RT-OK: kernel + qbin under rt-bind dest → passes (R-REACH ext.)"
)
# ── VDP-REACH-NO-RT-BIND (GREEN): no rt bind → extension inactive → passes ────
# GOOD_ARGV has no --ro-bind ... /rsdd/rt so the new check is a no-op.
assert_passes(
    lambda: m.check_disk_policy(list(GOOD_ARGV), run_dir=RUN_DIR),
    "VDP-REACH-NO-RT-BIND: no runtime-tree bind → R-REACH extension inactive → passes"
)

# ── VDP-BROAD-WARN-RESOLVED: resolved in broad set, typed safe → returns warning ──────
# Kills M7: removing the normed_resolved branch makes this return None.
# resolved="/usr" (in _BROAD_QEMU_ROOT_DIRS), typed="/opt/evil" (not in set).
# The resolved-check arm must be the sole reason a warning is returned.
try:
    _w = m.broad_qemu_root_message("/usr", "/opt/evil")
    assert _w is not None, "expected warning string but got None"
    assert "WARNING" in _w, f"warning missing 'WARNING' token: {_w!r}"
    ok("VDP-BROAD-WARN-RESOLVED: resolved in broad set, typed safe → warning (kills M7)")
except Exception as e:
    nok("VDP-BROAD-WARN-RESOLVED", str(e))

# ── VDP-BROAD-WARN-TYPED: typed in broad set, resolved safe → returns warning ─────────
# Kills M6 host-independently: removing the normed_typed branch makes this return None.
# resolved="/opt/x/bin" (NOT in set), typed="/bin" (in set).
# Using a synthetic resolved path that is not in the set isolates the typed-check arm.
try:
    _w = m.broad_qemu_root_message("/opt/x/bin", "/bin")
    assert _w is not None, "expected warning string but got None"
    assert "WARNING" in _w, f"warning missing 'WARNING' token: {_w!r}"
    ok("VDP-BROAD-WARN-TYPED: typed in broad set, resolved safe → warning (kills M6 host-independently)")
except Exception as e:
    nok("VDP-BROAD-WARN-TYPED", str(e))

# ── VDP-BROAD-NOWARN: neither resolved nor typed in broad set → returns None ──────────
try:
    _w = m.broad_qemu_root_message("/opt/x", "/opt/x")
    assert _w is None, f"expected None but got: {_w!r}"
    ok("VDP-BROAD-NOWARN: neither path in broad set → None (no false positives)")
except Exception as e:
    nok("VDP-BROAD-NOWARN", str(e))

# ── VDP-ROOT-WARN: /root is in the broad set → warning (issue #98, item 1) ────────────
# RED before fix: /root absent from _BROAD_QEMU_ROOT_DIRS → returns None.
try:
    _w = m.broad_qemu_root_message("/root", "/root")
    assert _w is not None, "expected warning for /root but got None"
    assert "WARNING" in _w, f"warning missing 'WARNING' token: {_w!r}"
    ok("VDP-ROOT-WARN: /root in broad set → warning")
except Exception as e:
    nok("VDP-ROOT-WARN", str(e))

# ── VDP-NORMPATH-TYPED-ROOT: normpath on typed catches /usr/../root via typed arm ────
# resolved="/opt/x" (not in set) isolates the typed-normpath arm.
# RED before fix: normed_typed = "/usr/../root" (no normpath) → not in set → None.
# GREEN after: normpath("/usr/../root") = "/root" → in set (with /root added) → warning.
# Kills normpath-removal mutation: removing normpath makes typed = "/usr/../root" → miss.
try:
    _w = m.broad_qemu_root_message("/opt/x", "/usr/../root")
    assert _w is not None, "expected warning for typed=/usr/../root but got None"
    assert "WARNING" in _w, f"warning missing 'WARNING' token: {_w!r}"
    ok("VDP-NORMPATH-TYPED-ROOT: normpath on typed catches /usr/../root (kills normpath mutation)")
except Exception as e:
    nok("VDP-NORMPATH-TYPED-ROOT", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
