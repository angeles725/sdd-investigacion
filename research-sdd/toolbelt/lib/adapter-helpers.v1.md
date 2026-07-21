# adapter-helpers.v1 — Research-SDD Shared Adapter Helpers

Contract for `lib/adapter_helpers.py`.  Higher-level helpers built on
`adapter_core` primitives.  New adapters (unblob, floss, capa, kaitai) import
from here.  Item-24 migrates existing adapters by replacing inline
duplications with these imports.

**Dependency direction**: `adapter_helpers` → `adapter_core` (never reversed).
This file is a library module, not an artifact adapter; no tool-registry row.

---

## Standard evidence envelope schema

Every adapter produces one JSON file per run.  `emit_evidence` writes it:

```json
{
  "schema":     "<adapter-schema-id>",
  "status":     "complete" | "failed",
  "input":      { "source": {path,size,sha256}, "staged": {path,size,sha256} },
  "isolation":  { "launcher": {path,size,sha256}, "profile": {…} },
  "limitations": [ "…" ],
  "errors":     [ "…" ],
  "<domain-key>": "…"   ← adapter-specific fields merged last
}
```

---

## `emit_evidence(*, stage, schema, domain, input_identity, isolation, limitations, errors, manifest_spec, manifest_cli, destination, timeout=60)`

Assembles the envelope, writes it, runs the manifest-CLI tail, publishes.

| Parameter | Type | Description |
|---|---|---|
| `stage` | `Path` | Staging directory (caller-created; must contain `engine/`) |
| `schema` | `str` | Schema id, e.g. `"pcap-evidence.v1"`.  **Must be a safe single filename component** (see below). |
| `domain` | `dict` | Adapter-specific fields merged into the envelope.  **Must not contain any of the 6 reserved keys** (see below). |
| `input_identity` | `dict` | `{"source": record, "staged": record}` from `stage_file()` |
| `isolation` | `dict` | `{"launcher": record, "profile": dict}` |
| `limitations` | `list[str]` | Human-readable limitation strings |
| `errors` | `list[str]` | Tool error strings from `run_bounded()` |
| `manifest_spec` | `dict` | Full `analysis-manifest.v1` spec (built by adapter) |
| `manifest_cli` | `Path` | Absolute path to `analysis_manifest.py` |
| `destination` | `Path` | Final publish path (must not exist) |
| `timeout` | `int` | Seconds for **every** manifest-CLI `subprocess.run` call.  Mandatory; default 60. |

Raises `ManifestError` (subclass of `AdapterError`) on any failure.
`timeout=` is never optional — omitting it from a direct `subprocess.run`
call was the repeat 4R finding this helper closes.

### `schema` — safe filename-component requirement

`schema` is used verbatim as `stage/{schema}.json`.  It **must** match
`^[A-Za-z0-9][A-Za-z0-9._-]*$`; otherwise `ManifestError` is raised immediately
before any I/O.  Rejected examples: `"../evil"` (path traversal), `"a/b"` (slash),
`".hidden"` (leading dot), `"a\x00b"` (NUL).

### `domain` — reserved-key prohibition

The envelope has six structural keys owned by `emit_evidence`:
`schema`, `status`, `input`, `isolation`, `limitations`, `errors`.

If `domain` contains any of these keys, `ManifestError` is raised naming the
offending key(s) before any I/O.  Silent override is no longer possible;
every collision is an error.

---

## `pcap_magic_check(path)`

Opens *path* with `O_NOFOLLOW` and validates the first 4 bytes against all
known libpcap (LE/BE × µs/ns) and pcapng magic values.
Raises `PcapMagicError` on bad magic, symlinks, or unreadable files.
Consolidates the duplication in `corroborate_pcap.py` and `pcap_flows.py`.

**O_NOFOLLOW note**: symlink rejection relies on `os.O_NOFOLLOW`, which is
obtained via `getattr(os, "O_NOFOLLOW", 0)`.  On Linux this flag is always
present and the kernel rejects symlinks at `open(2)`.  On platforms where
`O_NOFOLLOW` is absent (e.g. some non-Linux systems), the flag is silently
omitted and symlinks are **not** rejected.  The guarantee is Linux-specific.

**Importable constants**: `_PCAP_MAGIC` (frozenset of four libpcap magic
byte variants) and `_PCAPNG_MAGIC` (pcapng Section Header Block type) are
importable by item-24 adapters that need to replicate the same check inline
(e.g. `from adapter_helpers import _PCAP_MAGIC, _PCAPNG_MAGIC`).

---

## `squashfs_superblock(data, offset=0) → dict | None`

Parses and validates a SquashFS v4 LE superblock at *offset* in *data*
(`bytes` or `memoryview`).  Returns a field dict on success; `None` on bad
magic, failed validation, or **negative offset**.  Consolidates
`squashfs_extract.py` and `firmware_carve.py`.  Named constants:
`SQFS_SB_FMT`, `SQFS_SB_SIZE`, `SQFS_FLAG_EXPORTABLE`.

**Negative-offset guard**: `offset` must be ≥ 0.  `struct.unpack_from`
accepts negative offsets (treating them as `len(buf)+offset`), which could
allow a crafted buffer with valid superblock bytes near the end to pass the
bounds check and return a bogus result.  Any `offset < 0` returns `None`
immediately without further processing.

---

---

## `venv_root_for(tool_exe) → Path`

Resolves the Python venv root for a tool executable.  Used internally by
`bind_venv`; call it directly only when you need to inspect the root path
without building a full bwrap extension.

### Guard predicate (order matters — shape checks run before FS checks)

1. `real_exe = Path(os.path.realpath(tool_exe))` — resolve symlinks first.
2. Require `real_exe.parent.name == "bin"`; `root = real_exe.parent.parent`.
3. **SHAPE checks (pure, no FS access)**:
   - `str(root)` not in `_VENV_BLOCKED_EXACT`.
   - If `root.parts[:2] == ('/', 'home')`: require `len(root.parts) >= 4`.
     This rejects both `/home` (2 parts) *and* `/home/<user>` (3 parts).
     A venv under `/home/<user>/local/venvs/name` (4+ parts) is allowed.
   - Elif `root.parts[:2] == ('/', 'root')`: require `len(root.parts) >= 3`.
   - Else: require `len(root.parts) >= 3`.
4. **FS marker**: `(root / "pyvenv.cfg").is_file()`.
5. **Belt**: `root != Path(os.path.realpath(os.path.expanduser("~")))`.

Shape checks run **before** FS checks so callers can test shallow-path
rejection without a real filesystem (D-2: `/home/<user>/bin/tool`).

### Why `/home/<user>` is explicitly rejected

If a tool is installed as a wrapper script (not a pipx symlink) at
`~/bin/tool`, `os.path.realpath` resolves to `~/bin/tool` and
`venv_root_for` computes `root = ~/`.  Without the depth guard, `~/` would
be bound read-only inside the sandbox, exposing `.ssh/`, `.gnupg/`, and all
home-directory credentials to a process analysing hostile input.

The `/home/<user>` case has exactly 3 path parts — one below the general
`>= 3` threshold — so the per-family `>= 4` check catches it precisely.

### `_VENV_BLOCKED_EXACT`

```python
frozenset({"/", "/home", "/root", "/usr", "/bin", "/sbin", "/lib", "/lib64",
           "/etc", "/tmp", "/proc", "/sys", "/dev", "/run"})
```

Belt-and-suspenders for paths that reach the shape check at exactly the
boundary depth.  The depth checks above are the primary guard.

---

## `bind_venv(prefix, tool_exe, *, etc_ro_bind_try=(), writable=None) → list[str]`

Extends a bwrap prefix (produced by `adapter_core.sandbox()`) with the
tool's Python venv read-only bind.  Raises `VenvBindError` (NOT `assert` —
survives `python -O`) for every safety violation.

### What is inserted before the trailing `"--"`

1. `--dir` stubs for every path component of the venv root (required by
   bubblewrap to create the mount-namespace directory tree).
2. `--ro-bind venv_root venv_root` (read-only; no analysis artifact persists
   in the tool tree).
3. For each `entry` in `etc_ro_bind_try`: `--ro-bind-try entry entry`.
4. For each `(host_dir, sandbox_path)` in `writable`:
   `--dir sandbox_path` + `--bind host_dir sandbox_path`.

### `etc_ro_bind_try` — `_ETC_BIND_TRY_ALLOWED` policy

Only `/etc/passwd` and `/etc/group` are accepted:

```python
_ETC_BIND_TRY_ALLOWED = frozenset({"/etc/passwd", "/etc/group"})
```

This is a **deliberate narrow exception** to `adapter_core._RO_INPUT_BLOCKED_ROOTS`
(which blocks all of `/etc`).  vivisect (a floss dependency) calls
`getpass.getuser() → pwd.getpwuid()` which requires `/etc/passwd`; the
Python `grp` module requires `/etc/group`.  No other `/etc` paths are
permitted; any attempt raises `VenvBindError`.

`--ro-bind-try` is used (not `--ro-bind`) so that a missing path (e.g. on
LDAP-only systems) is silently skipped rather than aborting bubblewrap.

### Writable directories — deliberate bypass of `_RO_INPUT_BLOCKED_ROOTS`

Writable `host_dir` paths may live under `/home` (the adapter's private
output/temp directories, e.g. the unblob extraction dir).  They bypass
`_RO_INPUT_BLOCKED_ROOTS` because they are adapter-controlled, not arbitrary
user paths.  The guard instead requires:

- `sandbox_path.startswith("/tmp/rsdd/")` — scoped inside the sandbox tmpfs.
- `host_dir` exists, is a real directory, and is not a symlink (lstat check).

---

## `run_truncation(run_errors, tool) → tuple[bool, list[str]]`

Translates `run_bounded` cap-error tokens into a `(truncated_flag, limitations)` pair.

### Incomplete-run visibility convention

Adapters **MUST** OR the returned flag into their domain's `truncated` field:

```python
run_trunc, trunc_lims = run_truncation(run_errors, "mytool")
domain["my_section"]["truncated"] = domain["my_section"]["truncated"] or run_trunc
all_limitations += trunc_lims
```

This ensures that any cap fired by `run_bounded` — `"timeout"`, `"output-cap"`,
or `"process-cap"` — is always reflected in the evidence's `truncated` flag and
in a human-readable `limitations` string.  Truncation is **never silent**.

`"analyzer-exit:N"` is **not** a truncation event; it means the tool exited
with a non-zero code but was not cut short by a resource cap.

### `_RUN_CAP_ERRORS`

```python
frozenset({"timeout", "output-cap", "process-cap"})
```

### Limitation format

```
"<tool> run truncated: <cap> reached — inventory is incomplete"
```

One limitation string per fired cap, in sorted (alphabetical) order.

---

## Error classes

| Class | Base | When raised |
|---|---|---|
| `ManifestError` | `AdapterError` | manifest-CLI nonzero/timeout or publish failure |
| `PcapMagicError` | `AdapterError` | bad pcap magic, symlink, or unreadable file |
| `VenvBindError` | `AdapterError` | tool not inside a Python venv; unsafe venv root; invalid `etc_ro_bind_try` entry; invalid writable path; prefix does not end with `"--"` |
