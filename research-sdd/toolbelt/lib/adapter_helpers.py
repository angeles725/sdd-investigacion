#!/usr/bin/env python3
"""Shared higher-level adapter helpers for Research-SDD toolbelt adapters.

Built on top of adapter_core primitives.  New adapters (unblob, floss, capa,
kaitai) import from here instead of re-deriving the evidence envelope, the
manifest-CLI tail, and the format parsers that are duplicated across the
three modern adapters (corroborate_pcap.py, pcap_flows.py, squashfs_extract.py).

Item-24 will migrate the existing adapters by replacing inline duplications
with imports from this module.  This unit only ADDS; no existing adapter is
modified here.

Dependency direction: adapter_helpers → adapter_core (never the reverse).
"""
from __future__ import annotations

import os
import re
import stat
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Sibling import: adapter_core lives in the same lib/ directory.
# spec_from_file_location is used by the test harness, which does not insert
# lib/ into sys.path.  We do it ourselves to make `import adapter_core` work
# regardless of how this module was loaded.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import adapter_core as ac  # noqa: E402 (after sys.path fixup)
from adapter_core import AdapterError  # re-exported for callers that want one import

# ---------------------------------------------------------------------------
# pcap / pcapng magic-byte constants
# Duplicated in corroborate_pcap.py and pcap_flows.py — item-24 migrates both
# to import _PCAP_MAGIC and _PCAPNG_MAGIC from here.
# ---------------------------------------------------------------------------
# libpcap variants: little-endian microsecond, big-endian microsecond,
#                   little-endian nanosecond, big-endian nanosecond.
_PCAP_MAGIC: frozenset[bytes] = frozenset([
    b'\xd4\xc3\xb2\xa1',  # LE microsecond (most common)
    b'\xa1\xb2\xc3\xd4',  # BE microsecond
    b'\x4d\x3c\xb2\xa1',  # LE nanosecond
    b'\xa1\xb2\x3c\x4d',  # BE nanosecond
])
_PCAPNG_MAGIC: bytes = b'\x0a\x0d\x0d\x0a'  # pcapng Section Header Block type

# ---------------------------------------------------------------------------
# SquashFS v4 LE superblock constants
# Duplicated in squashfs_extract.py and firmware_carve.py — item-24 migrates
# both to import SQFS_* from here.
# ---------------------------------------------------------------------------
SQFS_SB_FMT: str = "<5I6H8Q"                    # 5×uint32 + 6×uint16 + 8×uint64
SQFS_SB_SIZE: int = struct.calcsize(SQFS_SB_FMT) # 96 bytes
SQFS_FLAG_EXPORTABLE: int = 0x80                 # superblock flags bit 7
_SQFS_MAGIC_BYTES: bytes = b"hsqs"               # LE on-disk representation
_SQFS_SENTINEL: int = 0xFFFFFFFFFFFFFFFF         # absent-table sentinel value


# ---------------------------------------------------------------------------
# Named error classes
# ---------------------------------------------------------------------------

class ManifestError(AdapterError):
    """Raised when any manifest-CLI step (create/validate/verify) or publish fails.

    Fail-closed: callers must handle this; there is no silent fallback.
    """


class PcapMagicError(AdapterError):
    """Raised when a file fails pcap/pcapng magic-byte validation.

    Also raised for symlinks (O_NOFOLLOW enforcement) and unreadable files.
    """


class VenvBindError(AdapterError):
    """Raised when a tool's venv root is unsafe to bind into the sandbox.

    Common causes:
    - Tool is a wrapper script (not a pipx symlink) whose realpath resolves to
      a shallow system path such as /home/<user>/bin/<tool> or /usr/bin/<tool>.
    - The tool's parent directory does not contain pyvenv.cfg (not a venv root).
    - The bwrap prefix does not end with '--'.
    - An etc_ro_bind_try entry or writable sandbox_path is outside the allowed set.

    Fix: point RSDD_<TOOL> at the venv's bin/<tool> directly.
    """


class BindScopeError(AdapterError):
    """Raised when a resolved path is unsafe to bind into a sandbox.

    Common causes:
    - Path is in the blocked-system-roots set (/, /home, /root, /usr, etc.).
    - /home/<user> path has fewer than 4 components (would expose the home dir).
    - Non-home path has fewer than 3 components (too shallow).
    - Path equals the real home directory (belt check).

    Every /home ro-bind in any adapter MUST route through assert_safe_bind_root
    to avoid silently exposing credential-bearing directories.
    """


# ---------------------------------------------------------------------------
# emit_evidence guards
# ---------------------------------------------------------------------------

# schema must be a safe single filename component: starts with alphanumeric,
# followed by zero or more alphanumerics, dots, underscores, or hyphens.
# Rejects '..' components, leading dots, slashes, NUL, and any other special
# character that could cause path-traversal when used as stage/{schema}.json.
_SAFE_SCHEMA_RE: re.Pattern[str] = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# Structural keys owned by emit_evidence; domain must not supply any of these.
_RESERVED_KEYS: frozenset[str] = frozenset(
    {"schema", "status", "input", "isolation", "limitations", "errors"}
)


# ---------------------------------------------------------------------------
# HELPER A — emit_evidence
# ---------------------------------------------------------------------------

def emit_evidence(
    *,
    stage: Path,
    schema: str,
    domain: dict[str, Any],
    input_identity: dict[str, Any],
    isolation: dict[str, Any],
    limitations: list[str],
    errors: list[str],
    manifest_spec: dict[str, Any],
    manifest_cli: Path,
    destination: Path,
    timeout: int = 60,
) -> None:
    """Assemble the standard evidence envelope and run the manifest-CLI tail.

    This is the common "tail" shared by all three modern adapters.  It
    centralises the timeout= omission that was a recurring 4R finding.

    Steps (all fail-closed; raises ManifestError on any failure):

    1. Assemble standard envelope:
         {schema, status, input, isolation, limitations, errors, **domain}
       status is "complete" when errors=[] else "failed".
    2. Write envelope as stage/{schema}.json via adapter_core.write (atomic).
    3. Write manifest_spec as stage/engine/manifest-spec.json.
    4. Run manifest_cli create  --root stage --spec … --output …  (timeout=)
    5. Unlink spec.
    6. Run manifest_cli validate …                                 (timeout=)
    7. Run manifest_cli verify  --root stage …                     (timeout=)
    8. adapter_core.publish(stage, destination).

    Parameters
    ----------
    stage:          Staging directory (already populated by the caller).
    schema:         Schema identifier string, e.g. "pcap-evidence.v1".
                    Must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ (safe single
                    filename component); ManifestError raised otherwise.
    domain:         Adapter-specific evidence fields merged into the envelope.
                    Must not contain any of the 6 reserved structural keys
                    {schema, status, input, isolation, limitations, errors};
                    ManifestError is raised if any collision is detected.
    input_identity: {"source": record, "staged": record} from stage_file().
    isolation:      {"launcher": record, "profile": dict}.
    limitations:    Human-readable limitation strings (passed through).
    errors:         Tool error strings collected during the analysis run.
    manifest_spec:  Full analysis-manifest spec dict (built by the adapter).
    manifest_cli:   Absolute path to analysis_manifest.py.
    destination:    Final publish path (must not exist).
    timeout:        Seconds applied to EVERY manifest-CLI subprocess.run call.
                    Mandatory; default 60. Raise ManifestError on expiry.
    """
    # Guard 1: schema must be a safe single-component filename to prevent
    # path traversal when building stage/{schema}.json.
    if not _SAFE_SCHEMA_RE.match(schema):
        raise ManifestError(
            f"unsafe schema identifier (must match ^[A-Za-z0-9][A-Za-z0-9._-]*$): {schema!r}"
        )
    # Guard 2: domain must not override structural envelope keys.
    collisions = _RESERVED_KEYS & domain.keys()
    if collisions:
        raise ManifestError(
            f"domain overrides reserved envelope key(s): {sorted(collisions)}"
        )
    status = "failed" if errors else "complete"
    envelope: dict[str, Any] = {
        "errors": errors,
        "input": input_identity,
        "isolation": isolation,
        "limitations": limitations,
        "schema": schema,
        "status": status,
        **domain,  # domain fields last so adapter can override envelope defaults
    }
    ac.write(stage / f"{schema}.json", envelope)

    spec_path = stage / "engine" / "manifest-spec.json"
    ac.write(spec_path, manifest_spec)

    manifest_path = stage / "engine" / "analysis-manifest.v1.json"
    cli_base = [sys.executable, str(manifest_cli)]

    def _run_cli(verb: str, extra: list[str]) -> None:
        """Run one manifest-CLI verb.  Always passes timeout=.  Fail-closed."""
        try:
            subprocess.run(cli_base + [verb] + extra, check=True, timeout=timeout)
        except subprocess.CalledProcessError as exc:
            raise ManifestError(
                f"manifest-cli '{verb}' failed (exit {exc.returncode})"
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise ManifestError(
                f"manifest-cli '{verb}' timed out after {timeout}s"
            ) from exc

    _run_cli("create", [
        "--root", str(stage),
        "--spec", str(spec_path),
        "--output", str(manifest_path),
    ])
    spec_path.unlink()
    _run_cli("validate", [str(manifest_path)])
    _run_cli("verify", ["--root", str(stage), str(manifest_path)])

    try:
        ac.publish(stage, destination)
    except (AdapterError, OSError) as exc:
        raise ManifestError(f"publish failed: {exc}") from exc


# ---------------------------------------------------------------------------
# HELPER B — pcap_magic_check
# ---------------------------------------------------------------------------

def pcap_magic_check(path: Path) -> None:
    """Open *path* with O_NOFOLLOW and validate pcap/pcapng magic bytes.

    Accepts:
    - libpcap: LE/BE × microsecond/nanosecond (four variants in _PCAP_MAGIC)
    - pcapng: Section Header Block magic (_PCAPNG_MAGIC)

    Raises PcapMagicError on:
    - Symlinks (O_NOFOLLOW enforced at the kernel level).
    - Unreadable or non-regular files.
    - Bad magic bytes (first 4 bytes do not match any known variant).

    Does not raise AdapterError subclasses other than PcapMagicError so that
    callers can narrow their except clauses.

    O_NOFOLLOW note: symlink rejection relies on getattr(os, "O_NOFOLLOW", 0).
    On Linux this flag is always present and the kernel rejects symlinks at
    open(2).  On platforms where O_NOFOLLOW is absent the flag is silently
    omitted and symlinks are not rejected — the guarantee is Linux-specific.
    """
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise PcapMagicError(
            f"cannot open (symlink or unreadable): {path}"
        ) from exc
    try:
        magic = os.read(fd, 4)
    finally:
        os.close(fd)
    if magic not in _PCAP_MAGIC and magic != _PCAPNG_MAGIC:
        raise PcapMagicError(
            f"not a pcap/pcapng file (magic 0x{magic.hex()}): {path}"
        )


# ---------------------------------------------------------------------------
# HELPER C — squashfs_superblock
# ---------------------------------------------------------------------------

def squashfs_superblock(
    data: bytes | memoryview,
    offset: int = 0,
) -> dict[str, Any] | None:
    """Parse and validate a SquashFS v4 LE superblock at *offset* in *data*.

    Returns a dict of parsed fields when the superblock at *offset* is a
    structurally valid SquashFS v4 LE superblock; returns None otherwise
    (wrong magic, failed validation, or insufficient bytes at *offset*).

    Struct layout (SQFS_SB_FMT = "<5I6H8Q"):
      uint32: magic, inodes, mtime, block_size, fragments
      uint16: compression, block_log, flags, ids, major, minor
      uint64: root_inode, bytes_used, id_table, xattr_table,
              inode_table, directory_table, fragment_table, export_table

    Validation rules (mirrors squashfs_extract.py and firmware_carve.py):
    - magic == b'hsqs'  (0x73717368 packed as LE uint32)
    - major == 4, minor == 0
    - compression in 1..6  (ZLIB=1, LZMA=2, LZO=3, XZ=4, LZ4=5, ZSTD=6)
    - block_size == 1 << block_log, 4096 ≤ block_size ≤ 1048576
    - inodes > 0, ids > 0
    - bytes_used ≥ SQFS_SB_SIZE, offset+bytes_used ≤ len(data)
    - table pointers: sentinel (0xfff…f) or SQFS_SB_SIZE ≤ ptr < bytes_used
    - required tables (id, inode, directory; fragment if fragments>0;
      export if SQFS_FLAG_EXPORTABLE set) must NOT be sentinel
    """
    # Guard: reject negative offsets — struct.unpack_from treats them as
    # len(buf)+offset, bypassing the bounds check below and potentially
    # returning a bogus superblock parsed from the end of the buffer.
    if offset < 0:
        return None
    data_len = len(data)
    if offset + SQFS_SB_SIZE > data_len:
        return None
    if bytes(data[offset:offset + 4]) != _SQFS_MAGIC_BYTES:
        return None
    try:
        fields = struct.unpack_from(SQFS_SB_FMT, data, offset)
    except struct.error:
        return None
    (_, inodes, mtime, block_size, fragments,
     compression, block_log, flags, ids, major, minor,
     root_inode, bytes_used,
     id_table, xattr_table, inode_table, directory_table,
     fragment_table, export_table) = fields

    end = offset + bytes_used

    def _valid_table(ptr: int) -> bool:
        return ptr == _SQFS_SENTINEL or (SQFS_SB_SIZE <= ptr < bytes_used)

    required = (
        [id_table, inode_table, directory_table]
        + ([fragment_table] if fragments else [])
        + ([export_table] if flags & SQFS_FLAG_EXPORTABLE else [])
    )

    if not (
        inodes > 0
        and ids > 0
        and major == 4
        and minor == 0
        and compression in range(1, 7)
        and block_size == (1 << block_log)
        and 4096 <= block_size <= 1048576
        and bytes_used >= SQFS_SB_SIZE
        and end <= data_len
        and all(_valid_table(x) for x in (
            id_table, xattr_table, inode_table,
            directory_table, fragment_table, export_table,
        ))
        and all(x != _SQFS_SENTINEL for x in required)
    ):
        return None

    return {
        "block_log": block_log,
        "block_size": block_size,
        "bytes_used": bytes_used,
        "compression": compression,
        "directory_table": directory_table,
        "export_table": export_table,
        "flags": flags,
        "fragment_table": fragment_table,
        "fragments": fragments,
        "id_table": id_table,
        "ids": ids,
        "inode_table": inode_table,
        "inodes": inodes,
        "major": major,
        "minor": minor,
        "mtime": mtime,
        "root_inode": root_inode,
        "xattr_table": xattr_table,
    }


# ---------------------------------------------------------------------------
# HELPER F — bind-scope guard (shared root-path safety predicate)
# ---------------------------------------------------------------------------
#
# Convention: every /home ro-bind in any adapter MUST route through
# assert_safe_bind_root() before calling _bind_tree or --ro-bind.  This is
# the single, canonical guard that prevents the U8/U10 class of block where a
# new bind was added without applying the scope check.
#
# Superset of all three former per-adapter blocked-root sets
# (_VENV_BLOCKED_EXACT, _RULES_BLOCKED_EXACT, _TOOLCHAIN_BLOCKED_EXACT).
# All three were identical; this shared set replaces all three.
_BLOCKED_BIND_ROOTS: frozenset[str] = frozenset({
    "/",
    "/home", "/root",
    "/usr", "/bin", "/sbin", "/lib", "/lib64",
    "/etc", "/tmp", "/proc", "/sys", "/dev", "/run",
})


def assert_safe_bind_root(resolved: Path) -> None:
    """Canonical bind-scope check — raises BindScopeError if *resolved* is unsafe to bind.

    Performs one filesystem access: ``os.path.realpath(os.path.expanduser("~"))``
    for the belt check (rule 4).  Rules applied in order:

    1. ``str(resolved) in _BLOCKED_BIND_ROOTS`` → reject (blocked system root).
    2. If ``resolved.parts[:2] == ('/', 'home')``: require ``len(parts) >= 4``.
       This rejects ``/home`` (2 parts) *and* ``/home/<user>`` (3 parts);
       ``/home/<user>/<subdir>`` (4+ parts) is allowed.
    3. Else: require ``len(parts) >= 3``.
    4. Belt (FS): reject if ``resolved == Path(os.path.realpath(os.path.expanduser("~")))``.
       Catches the case where a deep-enough home path resolves to the actual home
       directory after symlink traversal.

    Raises ``BindScopeError`` with a descriptive message on any failure.

    Every adapter that ro-binds a host directory MUST call this function before
    adding a ``--ro-bind`` argument to a bwrap prefix.  The three former inline
    copies (_VENV_BLOCKED_EXACT in adapter_helpers, _RULES_BLOCKED_EXACT in
    corroborate_capa, _TOOLCHAIN_BLOCKED_EXACT in corroborate_kaitai) have been
    consolidated here; no per-adapter copy should be added going forward.
    """
    s = str(resolved)
    if s in _BLOCKED_BIND_ROOTS:
        raise BindScopeError(f"path is a blocked system root: {s!r}")

    parts = resolved.parts
    if len(parts) >= 2 and parts[:2] == ("/", "home"):
        # /home and /home/<user> are 2 and 3 parts respectively — too broad.
        # Require /home/<user>/<subdir> (≥4 parts) to be safe.
        if len(parts) < 4:
            raise BindScopeError(
                f"path too broad to bind safely "
                f"(require /home/<user>/<subdir> or deeper, got {len(parts)} parts): {s!r}"
            )
    elif len(parts) < 3:
        raise BindScopeError(
            f"path too shallow to bind safely ({len(parts)} parts, need ≥3): {s!r}"
        )

    # Belt: reject the real home directory even if it passed shape checks
    # (e.g. a deeply-nested symlink that resolves to ~/.)
    home = Path(os.path.realpath(os.path.expanduser("~")))
    if resolved == home:
        raise BindScopeError(
            f"path resolves to the real home directory: {s!r}"
        )


# ---------------------------------------------------------------------------
# HELPER D — venv-bind helpers
# ---------------------------------------------------------------------------

# /etc paths permitted in etc_ro_bind_try.  This is a deliberate, narrow
# exception to adapter_core._RO_INPUT_BLOCKED_ROOTS: vivisect (a floss
# dependency) calls getpass.getuser() → pwd.getpwuid() which requires
# /etc/passwd; /etc/group is needed by the Python grp module.  No other
# /etc paths are allowed.
_ETC_BIND_TRY_ALLOWED: frozenset[str] = frozenset({
    "/etc/passwd",
    "/etc/group",
})

# run_bounded error tokens that indicate a resource cap fired, making the
# tool's output incomplete.  'analyzer-exit:N' is NOT a cap error — it means
# the tool ran to completion with a non-zero exit code.
# 'memory-cap' is emitted by kaitai_driver when RLIMIT_AS exhaustion fires
# inside the driver process (the driver catches MemoryError and sets a
# first-class flag rather than folding it into a generic parse_error).
_RUN_CAP_ERRORS: frozenset[str] = frozenset({
    "memory-cap",
    "output-cap",
    "process-cap",
    "timeout",
})

_VENV_BIND_MSG = (
    "tool is not inside a Python venv (wrapper script?); "
    "point RSDD_<TOOL> at the venv's bin/<tool>"
)


def venv_root_for(tool_exe: Path) -> Path:
    """Resolve the Python venv root for a tool executable.

    Guard predicate (ORDER MATTERS — scope check runs before FS marker so
    shape/belt rejection works without a real filesystem at the tool path):

    1. ``real_exe = Path(os.path.realpath(tool_exe))`` — resolve symlinks.
    2. Require ``real_exe.parent.name == "bin"``; ``root = real_exe.parent.parent``.
    3. SCOPE (delegated to ``assert_safe_bind_root``):
       Rejects blocked system roots, paths that are too broad or too shallow,
       and the real home directory (one FS access: realpath of ``~``).
       Raises ``VenvBindError`` (converted from ``BindScopeError``) with cause.
    4. FS marker: ``(root / "pyvenv.cfg").is_file()``.

    Raises ``VenvBindError`` on any failed check.
    """
    real_exe = Path(os.path.realpath(tool_exe))

    if real_exe.parent.name != "bin":
        raise VenvBindError(
            f"tool executable is not inside a 'bin/' directory: {tool_exe}"
        )
    root = real_exe.parent.parent

    # --- Scope + belt check via shared guard (one FS access: realpath of ~) ---
    # Design choice: catch BindScopeError and re-raise as VenvBindError to
    # preserve the exact exception type.  Callers (and tests D-2, D-3) explicitly
    # catch VenvBindError; letting BindScopeError propagate would silently break them
    # even though BindScopeError IS an AdapterError subclass.
    try:
        assert_safe_bind_root(root)
    except BindScopeError as exc:
        raise VenvBindError(_VENV_BIND_MSG) from exc

    # --- FS marker check (local — pyvenv.cfg is venv-specific, not generic) ---
    if not (root / "pyvenv.cfg").is_file():
        raise VenvBindError(_VENV_BIND_MSG)

    return root


def bind_venv(
    prefix: list[str],
    tool_exe: Path,
    *,
    etc_ro_bind_try: tuple[str, ...] = (),
    writable: list[tuple[Path, str]] | None = None,
) -> list[str]:
    """Extend a bwrap prefix with the tool's Python venv read-only bind.

    Inserts the following mounts BEFORE the trailing ``"--"`` in *prefix*:

    1. ``--dir`` stubs for every path component of the venv root so that the
       bind target exists in the new mount namespace.
    2. ``--ro-bind venv_root venv_root`` (read-only; no analysis artifact
       persists in the tool tree).
    3. For each entry in *etc_ro_bind_try*: ``--ro-bind-try entry entry``.
       Only paths in ``_ETC_BIND_TRY_ALLOWED`` are accepted; any other path
       raises ``VenvBindError``.  This is a deliberate narrow exception to
       ``adapter_core._RO_INPUT_BLOCKED_ROOTS`` — see that constant's docstring.
    4. For each ``(host_dir, sandbox_path)`` in *writable*:
       ``--dir sandbox_path`` + ``--bind host_dir sandbox_path``.
       ``sandbox_path`` must start with ``"/tmp/rsdd/"``; ``host_dir`` must
       exist, be a real directory, and not be a symlink.
       Note: writable host dirs may live under ``/home`` (the adapter's own
       output temp directories); they deliberately bypass ``_RO_INPUT_BLOCKED_ROOTS``
       because they are adapter-controlled, not arbitrary user paths.

    Raises ``VenvBindError`` (NOT ``assert`` — survives ``python -O``) when:
    - *prefix* does not end with ``"--"``.
    - ``venv_root_for(tool_exe)`` fails.
    - An *etc_ro_bind_try* entry is not in ``_ETC_BIND_TRY_ALLOWED``.
    - A *writable* ``sandbox_path`` does not start with ``"/tmp/rsdd/"``.
    - A *writable* ``host_dir`` does not exist, is not a directory, or is a symlink.

    Returns the new prefix ending with ``"--"``.
    """
    if not prefix or prefix[-1] != "--":
        raise VenvBindError(
            "bwrap prefix must end with '--' (produced by adapter_core.sandbox())"
        )

    venv_root = venv_root_for(tool_exe)

    extra: list[str] = []

    # Directory stubs for every ancestor component of the venv root.
    for i in range(1, len(venv_root.parts)):
        extra += ["--dir", str(Path(*venv_root.parts[:i + 1]))]
    extra += ["--ro-bind", str(venv_root), str(venv_root)]

    # /etc entries (narrow allowed set — see _ETC_BIND_TRY_ALLOWED).
    for entry in etc_ro_bind_try:
        if entry not in _ETC_BIND_TRY_ALLOWED:
            raise VenvBindError(
                f"etc_ro_bind_try entry {entry!r} is not in the allowed set "
                f"{sorted(_ETC_BIND_TRY_ALLOWED)}; only /etc/passwd and /etc/group "
                "are permitted (required by vivisect's getpwuid call)"
            )
        extra += ["--ro-bind-try", entry, entry]

    # Writable directories (adapter-controlled output/temp dirs).
    for host_dir, sandbox_path in (writable or []):
        sandbox_path = os.path.normpath(sandbox_path)
        if not sandbox_path.startswith("/tmp/rsdd/"):
            raise VenvBindError(
                f"writable sandbox_path must start with '/tmp/rsdd/': {sandbox_path!r}"
            )
        try:
            meta = host_dir.lstat()
        except OSError as exc:
            raise VenvBindError(
                f"writable host_dir does not exist or is not accessible: {host_dir}"
            ) from exc
        if stat.S_ISLNK(meta.st_mode):
            raise VenvBindError(
                f"writable host_dir must not be a symlink: {host_dir}"
            )
        if not stat.S_ISDIR(meta.st_mode):
            raise VenvBindError(
                f"writable host_dir must be a directory: {host_dir}"
            )
        extra += ["--dir", sandbox_path]
        extra += ["--bind", str(host_dir), sandbox_path]

    return prefix[:-1] + extra + ["--"]


# ---------------------------------------------------------------------------
# HELPER E — run_truncation
# ---------------------------------------------------------------------------

def run_truncation(run_errors: list[str], tool: str) -> tuple[bool, list[str]]:
    """Translate run_bounded cap errors into (truncated_flag, limitation_strings).

    Checks *run_errors* for the resource-cap tokens in ``_RUN_CAP_ERRORS``:
    ``"timeout"``, ``"output-cap"``, ``"process-cap"``, and ``"memory-cap"``.
    For each fired cap, one limitation string is produced.

    Note: ``"memory-cap"`` is normally surfaced via the driver's ``memory_cap``
    JSON field (caught inside the process) rather than via ``run_bounded``
    ``run_errors``; the token is included here so the vocabulary is complete and
    forward-compatible should the outer layer also emit it.

    ``"analyzer-exit:N"`` (non-zero tool exit without a cap) is explicitly NOT
    a truncation event — it means the tool ran to completion.

    Returns:
        ``(True, [limitation, ...])`` when at least one cap fired.
        ``(False, [])`` when no recognised cap is in *run_errors*.

    Limitation format (per cap, in sorted order):
        ``"<tool> run truncated: <cap> reached — inventory is incomplete"``

    Adapters MUST OR this flag into their domain ``truncated`` field to satisfy
    the incomplete-run visibility convention (any cap that fires → truncated true,
    never silent).
    """
    fired = sorted(_RUN_CAP_ERRORS & set(run_errors))
    limitations = [
        f"{tool} run truncated: {cap} reached — inventory is incomplete"
        for cap in fired
    ]
    return bool(fired), limitations
