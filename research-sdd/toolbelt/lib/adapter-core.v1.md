# adapter-core.v1 — Research-SDD Shared Adapter Primitives

Contract for `lib/adapter_core.py`. Adapters import from here instead of
duplicating implementations inline.  Item-24 migrates shipped adapters via
pure deletion + import (signatures are byte-compatible by design).

## Primitives

### `canonical_bytes(value) → bytes`
Deterministic JSON: `sort_keys=True`, no spaces, UTF-8 + newline.
Exported also as `canonical` for adapters that use the shorter name.

### `identity(path, max_bytes=None) → (resolved, size, sha256)`
Opens with `O_NOFOLLOW`. Raises `AdapterError` on symlinks, non-regular files,
TOCTOU (pre/post-read fstat mismatch), or size exceeding `max_bytes`.

### `stage_file(source, target, logical, mode, max_bytes=None) → (source_record, staged_record)`
Copies with `O_NOFOLLOW` + `O_EXCL`, verifies TOCTOU, confirms staged digest
equals in-flight digest. Both records carry `{path, size, sha256}`.

### `executable(name, configured, search) → (resolved_path, record)`
`shutil.which(name, path=search)` selects the binary; when `configured` is not
None, the configured path must match the PATH-selected one. `configured=None`
accepts the PATH-selected path directly (corroborate_native.py style).

### `require_private(path, mountinfo=None)`
**Fail-closed whitelist**: inspects `/proc/self/mountinfo` (or the supplied
string for testability) and raises `AdapterError` if the nearest enclosing
mount's filesystem type is NOT in `PRIVATE_FS`.  Unknown FS types are rejected
— this is a hard contract, not a soft warning.

Malformed mountinfo lines raise `AdapterError` with a descriptive message.
No raw `ValueError`/`IndexError` ever propagates to callers.

`PRIVATE_FS` = `{btrfs, ext2, ext3, ext4, f2fs, jfs, nilfs2, overlay, ramfs,
reiserfs, tmpfs, ubifs, xfs, zfs}`

### `sandbox(bwrap, env, ro_inputs=None) → list[str]`
Also exported as `isolation_prefix` (temporary item-24 migration bridge for
`corroborate_native.py`; prefer `sandbox` for all new code).

Hardened bwrap isolation profile — always includes:

| Flag | Effect |
|---|---|
| `--cap-drop ALL` | drop all Linux capabilities |
| `--unshare-pid` | new PID namespace |
| `--unshare-net` | network isolation (no outbound) |
| `--die-with-parent` | child killed when parent exits |
| `--new-session` | detach from controlling terminal |

Filesystem exposure: **minimal read-only bind** of OS runtime directories
(`/usr`, `/bin`, `/sbin`, `/lib`, `/lib64` where present) plus individual
dynamic-loader + TLS trust store helpers (`/etc/ld.so.cache`,
`/etc/ld.so.conf`, `/etc/ld.so.conf.d`, `/etc/ssl/certs`) via
`--ro-bind-try`.  DNS/NSS config (`/etc/resolv.conf`, `/etc/nsswitch.conf`)
is intentionally omitted — `--unshare-net` makes DNS unreachable so those
files have no effect.  The former `--ro-bind / /` full-root bind is
intentionally absent to prevent the sandboxed tool from reading SSH keys,
credentials, `/home`, or `/root`.

*ro_inputs*: list of caller-provided host paths (e.g., the target binary)
to bind read-only inside the sandbox.  **Validated before binding:**

- Normalised with `os.path.realpath()` to resolve symlinks (closes a
  symlink-to-root bypass).
- **Rejected** if the normalised path is `/` (filesystem root).
- **Rejected** if the normalised path equals or is under any of the restricted
  roots: `/home`, `/root`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`.  The check
  is a proper path-component prefix test — `/home` rejects `/home` and
  `/home/user/x` but **not** `/homeless`.  (`/run` is blocked because
  `/run/user/<uid>` holds keyring/gpg-agent sockets and `/run/secrets` is a
  credential mount.)
- The **resolved** (`realpath`) path is what `bwrap` binds — a symlink that
  validates cleanly cannot be swapped to point elsewhere before the kernel
  follows it at bind time.
- **Rejected** (raises `AdapterError`) if the path does not exist on the host;
  silently skipping a declared input is a foot-gun.

These rules preserve the sandbox hardening: a caller passing `ro_inputs=['/']`
would otherwise re-emit `--ro-bind / /`, recreating the full-root exposure that
U1-harden was designed to close.

Scratch root is a private tmpfs at `/tmp/rsdd`.  Raises `AdapterError` if
`/tmp/rsdd` is a symlink, owned by another user, or world-/group-writable.

### `run_bounded(command, cwd, env, timeout, max_bytes, max_processes=0) → (run_record, errors)`
Runs under `start_new_session=True`.  Enforced limits:

- Wall-clock ≥ `timeout` seconds → `"timeout"`
- `engine/stdout.txt` + `engine/stderr.txt` combined ≥ `max_bytes` → `"output-cap"`
- Total live PIDs in the process tree > `max_processes` (when > 0, via `/proc` enumeration) → `"process-cap"`
- `RLIMIT_FSIZE` preexec (defense-in-depth, best-effort)

Also exported as `run` (module-level alias, temporary item-24 migration bridge
for `corroborate_firmware.py`; prefer `run_bounded` for all new code).

On any cap/timeout both output files are jointly truncated to `max_bytes`.

### `write(path, value)`
Canonical JSON → fsync → `os.replace` (atomic, durable).

### `publish(stage, destination)`
`renameat2(RENAME_NOREPLACE)`.  Raises `OSError(EEXIST)` if destination exists.

## Error contract

All errors are `AdapterError(ValueError)`.  Adapters subclass for their own names:

```python
class NativeError(AdapterError): pass
```

The `main()` exit-2 pattern stays in each adapter:

```python
except (MyError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
    print(f"corroborate-X: {exc}", file=sys.stderr); return 2
```

## Migration note (item-24)

Known divergences fixed at migration time:

| Adapter | Old behaviour | Core behaviour |
|---|---|---|
| `corroborate_native.py::require_linux_private` | blacklist (fail-open) | whitelist (fail-closed) |
| `corroborate_ghidra.py::private_fs` | blacklist, no error handling | whitelist, AdapterError on malformed |
| `corroborate_native.py::isolation_prefix` | missing `--cap-drop ALL`, `--unshare-pid` | both present via `isolation_prefix` alias |
| `corroborate_java.py::isolation_prefix` | missing `--cap-drop ALL`, `--unshare-pid` | both present via `isolation_prefix` alias |
