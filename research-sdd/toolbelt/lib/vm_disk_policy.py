#!/usr/bin/env python3
"""Per-drive containment policy checker for RSDD VM detonation/trace plans.

Single source of truth for all disk-isolation rules in detonate/trace mode.
Imported by DetonateVmExecutor (D2) and TraceVmExecutor (D3) preflight so
trace can never ship a weaker policy than detonate.

Pure functions only — no subprocess, no live I/O.
"""
from __future__ import annotations
import os
import posixpath
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
# Partitioned by slice (D1 fix / issue #61): bwrap teeth are checked against
# the bwrap prefix only; inner required flags against the qemu-inner slice.
# A tooth appearing only after "--" satisfies set(argv) but bwrap never sees it.
# ---------------------------------------------------------------------------
_REQUIRED_BWRAP: frozenset[str] = frozenset({
    "--unshare-net",   # kernel net namespace isolation
    "--unshare-pid",   # PID namespace (guest cannot signal host processes)
    "--cap-drop",      # must be followed by ALL (value enforced in bwrap scan)
    "--tmpfs",         # scrubs writable temp tree; omitting exposes host /tmp/rsdd
})

_REQUIRED_INNER: frozenset[str] = frozenset({
    "-nic",            # no NIC (belt-and-suspenders with --unshare-net)
    "-accel",          # must be tcg (no /dev/kvm touch)
    "-smp",            # must be 1 (bound vCPUs)
    "-nodefaults",     # suppress all default devices
    "-sandbox",        # seccomp filter
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

# Value predicates enforced for each inner flag occurrence.
# --cap-drop is NOT here; it is checked separately in the bwrap prefix scan
# with a dedicated message naming "ALL" and the rule name (R-CAP-DROP).
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

# Sandbox destination for the runtime tree bind (must match emitters).
# When --qemu-root is used, emitters produce --ro-bind <host-src> /rsdd/rt.
_RT_TREE_DEST: str = "/rsdd/rt"

# ---------------------------------------------------------------------------
# R-INNER-ALLOWLIST — closed set of permitted qemu-inner flags (D2 fix / #61)
# ---------------------------------------------------------------------------
# Replaces the _BLOCK_DEVICE_FORBIDDEN denylist.  Every flag-shaped token
# (startswith("-")) in the qemu-inner slice MUST be a member of this set.
# Block-device introducers (-hda, -mtdblock, -blockdev, …) are absent by
# construction, so they are rejected without needing to enumerate them all.
# Verified against both emitters (detonate_plan.build_plan, trace_plan.build_plan):
#   detonate emits: -kernel -m -smp -accel -nic -nodefaults -sandbox
#                   -nographic -no-reboot -drive   (10 flags)
#   trace adds:     -append                        (+1, 11 total)
# A flag-shaped value token is impossible in the current emitters (no value
# begins with "-"); if one appears, it is flagged as unknown — fail-closed.
_QEMU_INNER_ALLOWED: frozenset[str] = frozenset({
    "-kernel",      # VM kernel image path
    "-m",           # memory size (MB)
    "-smp",         # vCPU count (must be 1)
    "-accel",       # accelerator (must be tcg)
    "-nic",         # NIC type (must be none)
    "-nodefaults",  # suppress default devices (boolean)
    "-sandbox",     # seccomp filter (on,...)
    "-nographic",   # no graphical output (boolean)
    "-no-reboot",   # exit instead of rebooting (boolean)
    "-append",      # kernel cmdline (trace-only; not emitted by detonate)
    "-drive",       # block device via -drive spec (only sanctioned path)
})

# ---------------------------------------------------------------------------
# R-BWRAP-DENY — fail-open bwrap bind families (INV-2 / issue #60)
# ---------------------------------------------------------------------------
# These variants fail OPEN when the source path is missing, which would
# silently reproduce the F5 failure mode (unreachable drive, no error surface).
# The -try variants are forbidden for this reason; the overlay and dev-bind
# families expose unintended host paths.
_BWRAP_DENIED: frozenset[str] = frozenset({
    "--dev-bind",      # device bind (exposes host device nodes)
    "--dev-bind-try",  # fail-open device bind
    "--bind-try",      # fail-open rw bind (silently succeeds on missing src)
    "--ro-bind-try",   # fail-open ro bind (silently succeeds on missing src)
    "--overlay",       # overlay mount (multiple host layers)
    "--overlay-src",   # companion to --overlay
    "--tmp-overlay",   # temporary overlay (auto-cleaned)
    "--ro-overlay",    # read-only overlay
})

# Arities of known bwrap mount ops (number of following arguments consumed).
# Unknown tokens are NOT consumed — the parser only advances for known ops.
# This is intentional: limiting the parser to known ops keeps the invariant
# conservative and safe; unknown ops are left in place for future extension.
_BWRAP_MOUNT_ARITY: dict[str, int] = {
    "--tmpfs":        1,
    "--bind":         2,
    "--ro-bind":      2,
    "--dir":          1,
    "--proc":         1,
    "--dev":          1,
    "--symlink":      2,
    "--perms":        1,
    "--chmod":        2,
    # The following are recognized but forbidden (parsed to skip args on the
    # deny path; they raise GateError before coverage logic is reached).
    "--dev-bind":     2,
    "--dev-bind-try": 2,
    "--bind-try":     2,
    "--ro-bind-try":  2,
    "--overlay":      3,  # SRC DEST [SRC ...] — variable, treat as 3 minimum
    "--overlay-src":  1,
    "--tmp-overlay":  2,
    "--ro-overlay":   2,
}


# ---------------------------------------------------------------------------
# Broad qemu-root warning (issue #89)
# ---------------------------------------------------------------------------

# System directories broad enough to materially widen the sandbox escape surface
# when bound read-only via --qemu-root.  This set is checked against BOTH the
# user-typed path (after trailing-slash normalization) and the realpath-resolved
# path, so canonical names like /bin are caught even when they are symlinks to
# /usr/bin on modern distros, and symlink indirection into a broad dir is also
# caught (e.g. a symlink /opt/evil -> /usr resolves to /usr, which is in the set).
_BROAD_QEMU_ROOT_DIRS: frozenset[str] = frozenset({
    "/", "/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc",
    # /root has the same credential-exposure profile as /etc — both expose sensitive
    # system files to any process reading the ro-bound sandbox tree.
    "/root",
})


def broad_qemu_root_message(resolved_src: str, typed_src: str) -> str | None:
    """Return a warning string if qemu-root names a broad system directory, else None.

    Both typed_src (normalized) and resolved_src (realpath) are checked against
    _BROAD_QEMU_ROOT_DIRS.  Checking the typed path catches canonical broad names
    even when they are symlinks (e.g. /bin -> /usr/bin on merged-usr distros).
    Checking the resolved path catches anti-evasion via symlink indirection into a
    broad directory (e.g. /opt/evil -> /usr).

    This is a pure function — no filesystem I/O.  The caller resolves symlinks
    (os.path.realpath) and passes both the original and resolved strings.
    """
    # normpath collapses ".." traversal sequences in the typed string without
    # filesystem I/O, so "/usr/../root" → "/root".  This is belt-and-suspenders
    # on top of the realpath-resolved check: realpath already handles traversal
    # and symlinks, but normpath guards the typed-path arm independently and
    # provides correctness on systems where canonical paths diverge (e.g.
    # macOS /etc → /private/etc means rstrip alone would miss canonical names).
    normed_typed = os.path.normpath(typed_src) if typed_src else "/"
    normed_resolved = resolved_src.rstrip("/") or "/"
    if normed_typed not in _BROAD_QEMU_ROOT_DIRS and normed_resolved not in _BROAD_QEMU_ROOT_DIRS:
        return None
    return (
        f"WARNING: --qemu-root {typed_src!r} binds a broad system directory "
        "read-only into the sandbox, widening the escape surface unnecessarily; "
        "consider using a curated runtime tree instead"
    )


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
    # ---- 1. Required flags: slice-scoped (D1 fix / issue #61) ------------
    # a. The "--" separator defines the two slices; check it first.
    if "--" not in argv:
        raise GateError(
            "planned_argv missing '--' separator (required bwrap/qemu boundary)"
        )
    sep_idx = argv.index("--")
    bwrap_prefix = argv[:sep_idx]
    inner = argv[sep_idx + 1:]

    # b. Bwrap teeth must be in the bwrap prefix, not the qemu-inner slice.
    #    A tooth relocated to the inner slice satisfies set(argv) but bwrap
    #    never receives it — hence a slice-scoped check, not set(argv).
    missing_bwrap = sorted(_REQUIRED_BWRAP - set(bwrap_prefix))
    if missing_bwrap:
        raise GateError(
            f"planned_argv bwrap prefix missing required containment "
            f"flag(s): {missing_bwrap}"
        )

    # c. Qemu-inner required flags must be in the inner slice.  Relocating
    #    -smp or -sandbox before -- satisfies set(argv) but qemu never sees them.
    missing_inner = sorted(_REQUIRED_INNER - set(inner))
    if missing_inner:
        raise GateError(
            f"planned_argv qemu-inner slice missing required containment "
            f"flag(s): {missing_inner}"
        )

    # ---- 2. Token scan: R-BWRAP-DENY + cap-drop value; R-INNER-ALLOWLIST,
    #         qemu forbidden flags, device deny, value predicates, drive class. -
    persistent_drives: list[str] = []  # file= paths of writable-persistent drives
    all_drive_paths:   list[str] = []  # file= paths of every -drive slot (R-REACH)

    # Bwrap prefix scan: R-BWRAP-DENY + --cap-drop value check (R-CAP-DROP).
    for i, tok in enumerate(bwrap_prefix):
        if tok in _BWRAP_DENIED:
            raise GateError(
                f"planned_argv contains forbidden bwrap op {tok!r} "
                "(R-BWRAP-DENY: fail-open bind families are refused — "
                "they silently reproduce the F5 failure mode when src is missing)"
            )
        if tok == "--cap-drop":
            nxt_b = bwrap_prefix[i + 1] if i + 1 < len(bwrap_prefix) else ""
            if nxt_b != "ALL":
                raise GateError(
                    f"--cap-drop must be 'ALL' (partial drop insufficient, "
                    f"got {nxt_b!r}) (R-CAP-DROP)"
                )

    # Qemu-inner scan: forbidden flags, device deny, value predicates,
    # drive classification, and R-INNER-ALLOWLIST catch-all (step 5 in section 2.2).
    # Specific diagnostics (_FORBIDDEN, -device) fire before the catch-all so
    # operators see the precise message for known bad flags.
    # Also collects kernel_path for the R-REACH extension below (gaps 3/4).
    kernel_path: str = ""
    qbin_in_tree: str = inner[0] if inner else ""  # first token after --
    for i, tok in enumerate(inner):
        nxt = inner[i + 1] if i + 1 < len(inner) else ""

        if tok == "-kernel":
            kernel_path = nxt

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
            _check_one_drive(nxt, persistent_drives, all_drive_paths)

        # R-INNER-ALLOWLIST catch-all: flag-shaped tokens not in the closed
        # permitted set are rejected.  Block-device introducers (-hda, -mtdblock,
        # -blockdev, …) are absent from the set by construction, closing the gap
        # that _BLOCK_DEVICE_FORBIDDEN (a denylist) could not enumerate completely.
        if tok.startswith("-") and tok not in _QEMU_INNER_ALLOWED:
            raise GateError(
                f"planned_argv inner flag {tok!r} is not in the permitted "
                "qemu-inner flag set (R-INNER-ALLOWLIST); block-device "
                "introducers and other unchecked flags are rejected by "
                "construction — only the 11 emitter-verified flags are allowed"
            )

    # ---- 3. Exactly one writable-persistent (scratch) drive ---------------
    if len(persistent_drives) != 1:
        raise GateError(
            f"planned_argv must contain exactly 1 writable-persistent drive "
            f"(the scratch disk); found {len(persistent_drives)}"
        )
    scratch_drive_path = persistent_drives[0]

    # ---- 4. All drive file= paths under run_dir or a recognized sandbox input -
    # (R-SCOPE-ALL — D3 fix / issue #61)
    # Two-part fix: (a) the writable-persistent scratch is ALWAYS run_dir-scoped
    # unconditionally before the loop (restores pre-#61 behaviour; the /input/
    # prefix exemption was a regression — R-BIND-RW already pins the scratch
    # --bind to scratch_drive_path, see step 5); (b) the exemption for read-only
    # sandbox inputs uses posixpath.normpath so traversal sequences like
    # /input/../etc/shadow collapse to /etc/shadow, which is not in the known set.
    if run_dir is not None:
        prefix = run_dir.rstrip("/") + "/"
        # (a) Scratch always scoped — unconditional, regardless of path prefix.
        if not scratch_drive_path.startswith(prefix):
            raise GateError(
                f"drive file={scratch_drive_path!r} is outside "
                f"run_dir={run_dir!r}; the writable-persistent scratch must "
                "reside in the per-run directory (R-SCOPE-ALL)"
            )
        for dp in all_drive_paths:
            # (b) Exempt only the two known read-only sandbox-internal DESTs;
            # normpath collapses traversal so /input/../etc/shadow → /etc/shadow
            # (not in set) and falls through to the run_dir scope check.
            if posixpath.normpath(dp) in {_SAMPLE_GUEST_PATH, _ROOTFS_GUEST_PATH}:
                continue  # recognized RO sandbox input; host copy is ro-bind SRC
            if not dp.startswith(prefix):
                raise GateError(
                    f"drive file={dp!r} is outside run_dir={run_dir!r} and is not "
                    "a recognized sandbox input path; every non-sandbox drive "
                    "file= path must reside in the per-run directory so host reads "
                    "post-teardown stay scoped (R-SCOPE-ALL)"
                )

    # ---- 5. R-BIND-RW — exactly one rw bind, identity-mapped, == scratch ──
    # (INV-2 / issue #60)
    # Rule: at most ONE --bind (rw) op; SRC must equal DEST; that path must
    # equal the writable-persistent drive path collected above.
    # All other binds must be --ro-bind (enforced by the R-BWRAP-DENY deny
    # list plus this scan).
    rw_binds: list[tuple[str, str]] = []  # (SRC, DEST) of each --bind
    i = 0
    while i < len(bwrap_prefix):
        tok = bwrap_prefix[i]
        if tok == "--bind":
            src  = bwrap_prefix[i + 1] if i + 1 < len(bwrap_prefix) else ""
            dest = bwrap_prefix[i + 2] if i + 2 < len(bwrap_prefix) else ""
            rw_binds.append((src, dest))
            i += 3
        else:
            i += 1

    if len(rw_binds) != 1:
        raise GateError(
            f"planned_argv must contain exactly 1 read-write --bind op "
            f"(the scratch file bind); found {len(rw_binds)} "
            "(R-BIND-RW: one --bind required for scratch reachability)"
        )
    bind_src, bind_dest = rw_binds[0]
    if bind_src != bind_dest:
        raise GateError(
            f"planned_argv --bind SRC {bind_src!r} != DEST {bind_dest!r}: "
            "the rw bind must be identity-mapped (SRC == DEST) to prevent "
            "host-path indirection (R-BIND-RW)"
        )
    if bind_src != scratch_drive_path:
        raise GateError(
            f"planned_argv --bind {bind_src!r} does not match scratch drive "
            f"path {scratch_drive_path!r}: the rw bind must be file-scoped to "
            "the scratch image exactly (R-BIND-RW). A directory bind exposes the "
            "host run_dir to guest writes; vm_boot_core.output_files() sweeps that "
            "directory into receipt outputs[], enabling a qemu escape to inject "
            "artifacts into the frozen evidence chain. See design.md §3.2."
        )

    # ---- 6. R-REACH — every -drive file= path reachable under mount ops ───
    # (INV-2 / issue #60)
    # Parse bwrap mount ops in order; for each -drive file=P, walk the ops
    # maintaining a 'covered' boolean.  Final covered=False → GateError.
    # Ordering is load-bearing: --bind before --tmpfs is silently re-masked.
    # This check runs on the full argv (bwrap prefix only) and is
    # substitution-invariant: sentinel paths work as well as real paths.
    # For ro-bound drives the file= value equals the bind DEST (sandbox path),
    # not the host path — see _check_drive_reachable docstring.
    for drive_path in all_drive_paths:
        _check_drive_reachable(bwrap_prefix, drive_path)

    # ---- 6b. R-REACH: kernel + qemu binary (gaps 1/3/4). Active when rt bind present.
    _rt_bind_present = any(
        bwrap_prefix[i] == "--ro-bind" and i + 2 < len(bwrap_prefix)
        and bwrap_prefix[i + 2] == _RT_TREE_DEST
        for i in range(len(bwrap_prefix))
    )
    if _rt_bind_present:
        if kernel_path and kernel_path.startswith("/"):
            _check_drive_reachable(bwrap_prefix, kernel_path)
        if qbin_in_tree and qbin_in_tree.startswith("/"):
            _check_binary_reachable(bwrap_prefix, qbin_in_tree)


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


def _check_one_drive(spec: str, persistent_out: list[str], all_out: list[str]) -> None:
    """Validate a single -drive spec string; append to persistent_out if writable-persistent.

    Also appends the ``file=`` path to *all_out* unconditionally so R-REACH can
    verify every drive slot, not only the writable-persistent one.

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
    all_out.append(file_path)  # every drive path must be reachable (R-REACH)


def _check_drive_reachable(bwrap_prefix: list[str], drive_path: str) -> None:
    """Assert that drive_path is reachable under the bwrap mount ops (R-REACH).

    Walks the bwrap prefix left-to-right, maintaining a 'covered' flag for
    drive_path.  A --bind or --ro-bind whose DEST is a prefix of (or equal to)
    drive_path sets covered=True.  A subsequent --tmpfs whose DEST is a prefix
    of (or equal to) drive_path resets covered=False (masks the earlier bind).

    After processing all ops: covered=False → GateError.

    This is order-aware, not set-based.  A --bind placed before a --tmpfs that
    covers the same subtree is silently re-masked — this is the F5 failure mode.
    The function detects that case by tracking the running covered state.

    Parameters
    ----------
    bwrap_prefix:
        The bwrap portion of the full argv (everything before the ``--``
        separator that separates the outer sandbox command from the inner qemu
        command).
    drive_path:
        The ``file=`` value of the drive to check.  For the scratch drive this
        is the host-side path; for ro-bound drives (sample, rootfs) it is the
        sandbox bind DEST (``/input/sample``, ``/input/rootfs``).  The check
        works precisely because it compares against bind DESTs, not host paths.
    """
    covered = False
    i = 0
    while i < len(bwrap_prefix):
        tok = bwrap_prefix[i]
        arity = _BWRAP_MOUNT_ARITY.get(tok, 0)

        if tok in ("--bind", "--ro-bind"):
            # SRC = bwrap_prefix[i+1], DEST = bwrap_prefix[i+2]
            dest = bwrap_prefix[i + 2] if i + 2 < len(bwrap_prefix) else ""
            # A bind covers drive_path when:
            #   drive_path == dest  (identity / file-scoped bind — the only
            #                        allowed form under R-BIND-RW), OR
            #   drive_path starts with dest + "/" (subtree bind — broader, also
            #                        covers; we check both forms for generality).
            dest_prefix = dest.rstrip("/")
            if drive_path == dest_prefix or drive_path.startswith(dest_prefix + "/"):
                covered = True

        elif tok == "--tmpfs":
            dest = bwrap_prefix[i + 1] if i + 1 < len(bwrap_prefix) else ""
            dest_prefix = dest.rstrip("/")
            # --tmpfs masks drive_path when drive_path is at or under dest.
            if drive_path == dest_prefix or drive_path.startswith(dest_prefix + "/"):
                covered = False  # previous bind (if any) is now re-masked

        i += max(arity + 1, 1)  # advance past the op and its args

    if not covered:
        raise GateError(
            f"planned_argv drive file={drive_path!r} is not reachable inside the "
            "sandbox: no --bind or --ro-bind covers that path after all bwrap "
            "mount ops are applied in argv order (R-REACH / INV-2). "
            "A --bind placed BEFORE a --tmpfs that covers the same subtree is "
            "silently re-masked — check mount-op ordering."
        )


def _check_binary_reachable(bwrap_prefix: list[str], qbin_path: str) -> None:
    """Assert qemu binary is reachable in the sandbox (R-REACH ext. for gap 1).

    Same order-aware coverage walk as _check_drive_reachable; separate function
    so the error message names the binary rather than 'drive file='.
    """
    covered = False
    i = 0
    while i < len(bwrap_prefix):
        tok = bwrap_prefix[i]
        arity = _BWRAP_MOUNT_ARITY.get(tok, 0)
        if tok in ("--bind", "--ro-bind"):
            dest = bwrap_prefix[i + 2] if i + 2 < len(bwrap_prefix) else ""
            dest_prefix = dest.rstrip("/")
            if qbin_path == dest_prefix or qbin_path.startswith(dest_prefix + "/"):
                covered = True
        elif tok == "--tmpfs":
            dest = bwrap_prefix[i + 1] if i + 1 < len(bwrap_prefix) else ""
            dest_prefix = dest.rstrip("/")
            if qbin_path == dest_prefix or qbin_path.startswith(dest_prefix + "/"):
                covered = False
        i += max(arity + 1, 1)
    if not covered:
        raise GateError(
            f"planned_argv qemu binary {qbin_path!r} is not reachable inside the "
            "sandbox: no --bind or --ro-bind covers that path after all bwrap "
            "mount ops are applied in argv order (R-REACH / INV-2). "
            "Ensure the runtime-tree bind (--ro-bind <src> /rsdd/rt) appears "
            "after --tmpfs and covers the binary path."
        )
