#!/usr/bin/env python3
"""Per-drive containment policy checker for RSDD VM detonation/trace plans.

Single source of truth for all disk-isolation rules in detonate/trace mode.
Imported by DetonateVmExecutor (D2) and TraceVmExecutor (D3) preflight so
trace can never ship a weaker policy than detonate.

Pure functions only — no subprocess, no live I/O.
"""
from __future__ import annotations
import sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from gate import GateError  # noqa: E402

# ---------------------------------------------------------------------------
# V1b containment belt retained in detonate/trace mode, minus the global
# -snapshot requirement (replaced by per-drive policy).
# ---------------------------------------------------------------------------
_REQUIRED: frozenset[str] = frozenset({
    "--unshare-net",   # bwrap outer: kernel net namespace isolation
    "-nic",            # qemu inner: no NIC (belt-and-suspenders with --unshare-net)
    "-accel",          # qemu inner: must be tcg (no /dev/kvm touch)
    "-smp",            # qemu inner: must be 1 (bound vCPUs)
    "-nodefaults",     # qemu inner: suppress all default devices
    "-sandbox",        # qemu inner: seccomp filter
})

# Flags forbidden wholesale — any occurrence → GateError.
_FORBIDDEN: frozenset[str] = frozenset({
    "-virtfs",     # host-FS sharing via Plan 9 virtio (escape vector)
    "-fsdev",      # companion to -virtfs (9p backend)
    "-enable-kvm", # hypervisor acceleration (offline-only policy; user must opt in manually)
    "-runas",      # privilege change inside qemu
    "-net",        # legacy network device (rejected: -nic none covers all variants)
    "-netdev",     # modern network backend (rejected: belt-and-suspenders)
})

# -device values whose prefix must never appear (passthrough / host-FS vectors).
_DEVICE_DENY_PREFIXES: tuple[str, ...] = ("vfio", "virtio-9p")

# Value predicates enforced on every occurrence of each flag.
_VALUE_OK: dict[str, Any] = {
    "-nic":     lambda v: v == "none",
    "-accel":   lambda v: v == "tcg",
    "-sandbox": lambda v: v.startswith("on") and "=allow" not in v,
    "-smp":     lambda v: v == "1",
}

# Conventional guest-visible paths for bwrap ro-bind inputs in RSDD plans.
# The sample must be immutable; the rootfs must be either readonly or COW.
_SAMPLE_GUEST_PATH: str = "/input/sample"
_ROOTFS_GUEST_PATH: str = "/input/rootfs"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def check_disk_policy(argv: list[str], *, run_dir: str | None = None) -> None:
    """Enforce per-drive VM containment policy on a planned_argv list.

    Raises GateError on any violation.

    Parameters
    ----------
    argv:
        The full planned_argv (bwrap prefix + qemu inner command) as a flat
        list of strings — exactly as it would be passed to subprocess.Popen.
    run_dir:
        When provided, the scratch disk's ``file=`` path is additionally
        verified to be under this directory (the per-run host directory the
        executor creates and reads from post-teardown).  Pass ``None`` at
        plan-generation time when the run_dir is not yet known.
    """
    # ---- 1. Required flags ------------------------------------------------
    present = set(argv)
    missing = sorted(_REQUIRED - present)
    if missing:
        raise GateError(
            f"planned_argv missing required containment flag(s): {missing}"
        )

    # ---- 2. Token scan: forbidden flags, device deny, value predicates ----
    persistent_drives: list[str] = []  # file= paths of writable-persistent drives

    for i, tok in enumerate(argv):
        nxt = argv[i + 1] if i + 1 < len(argv) else ""

        if tok in _FORBIDDEN:
            raise GateError(f"planned_argv contains forbidden flag {tok!r}")

        if tok == "-device" and nxt.startswith(_DEVICE_DENY_PREFIXES):
            raise GateError(
                f"planned_argv -device {nxt!r} forbidden "
                "(host passthrough / virtio-9p refused)"
            )

        rule = _VALUE_OK.get(tok)
        if rule and not rule(nxt):
            raise GateError(
                f"planned_argv {tok} value {nxt!r} violates containment"
            )

        if tok == "-drive":
            _check_one_drive(nxt, persistent_drives)

    # ---- 3. Exactly one writable-persistent (scratch) drive ---------------
    if len(persistent_drives) != 1:
        raise GateError(
            f"planned_argv must contain exactly 1 writable-persistent drive "
            f"(the scratch disk); found {len(persistent_drives)}"
        )

    # ---- 4. Scratch file= path must be under run_dir (when known) ---------
    if run_dir is not None:
        scratch = persistent_drives[0]
        prefix = run_dir.rstrip("/") + "/"
        if not scratch.startswith(prefix):
            raise GateError(
                f"scratch disk file={scratch!r} is outside run_dir={run_dir!r}; "
                "scratch must reside in the per-run directory (host reads it "
                "post-teardown)"
            )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _parse_drive_kv(spec: str) -> dict[str, str]:
    """Parse a -drive value string (k=v,k2=v2,...) into a dict.

    Bare keys (no ``=``) are stored with an empty-string value.
    """
    out: dict[str, str] = {}
    for part in spec.split(","):
        part = part.strip()
        if "=" in part:
            k, _, v = part.partition("=")
            out[k.strip()] = v.strip()
        elif part:
            out[part] = ""
    return out


def _check_one_drive(spec: str, persistent_out: list[str]) -> None:
    """Validate a single -drive spec string; append to persistent_out if writable-persistent.

    Raises GateError on any violation.
    """
    d = _parse_drive_kv(spec)
    file_path = d.get("file", "")
    # Guard: reject drive with missing or empty file= key — fail-closed (Fix 2).
    if not file_path:
        raise GateError(
            "planned_argv -drive spec missing or empty 'file=' key — refused (fail-closed)"
        )
    fmt = d.get("format", "")
    readonly = d.get("readonly", "off")
    snapshot = d.get("snapshot", "off")

    # Rule: format=raw mandatory (qcow2 backing-file = host-path escape vector).
    if fmt != "raw":
        raise GateError(
            f"planned_argv -drive format must be 'raw' (got {fmt!r}); "
            "non-raw formats are forbidden — qcow2 backing-file is a host-path escape"
        )

    # Rule: host device paths forbidden.
    if file_path.startswith("/dev/"):
        raise GateError(
            f"planned_argv -drive file={file_path!r} is a host device path — refused"
        )

    # Rule: /input/sample MUST be readonly=on (sample identity is immutable;
    # even COW overlay is refused — detonation must never alter sample state).
    if file_path == _SAMPLE_GUEST_PATH and readonly != "on":
        raise GateError(
            f"planned_argv -drive file={_SAMPLE_GUEST_PATH!r} must be readonly=on; "
            "sample disk must be immutable (readonly=on required, COW refused)"
        )

    # Rule: /input/rootfs must be snapshot=on (COW) or readonly=on.
    if file_path == _ROOTFS_GUEST_PATH and readonly != "on" and snapshot != "on":
        raise GateError(
            f"planned_argv -drive file={_ROOTFS_GUEST_PATH!r} must be snapshot=on "
            "or readonly=on (rootfs must be ephemeral — guest OS tampering discarded)"
        )

    # Classify drive into one of three permitted classes:
    #   readonly-fixed: readonly=on (sample)       → immutable, never writable
    #   COW:            snapshot=on                → writes go to transient overlay
    #   persistent:     snapshot=off, not readonly → scratch; must be exactly 1
    if readonly == "on":
        pass  # readonly-fixed class
    elif snapshot == "on":
        pass  # COW class
    else:
        # Writable-persistent class: the scratch disk.
        persistent_out.append(file_path)
