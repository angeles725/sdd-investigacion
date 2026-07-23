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
SAMPLE_DRIVE  = "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio"
SCRATCH_DRIVE = f"file={RUN_DIR}/scratch.img,snapshot=off,format=raw,if=virtio"
ROOTFS_DRIVE  = "file=/input/rootfs,snapshot=on,format=raw,if=virtio"

GOOD_ARGV = [
    "bwrap", "--die-with-parent", "--new-session",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
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
_t8_argv = swap_drive(GOOD_ARGV, SCRATCH_DRIVE,
    "file=/rsdd/scratch.img,snapshot=off,format=raw,if=virtio")
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

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
