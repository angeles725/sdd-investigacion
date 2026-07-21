# `capa-evidence.v1`

`corroborate-capa.sh --input <binary> --output <new-out-dir> [--rules <dir>] [--timeout N] [--max-capabilities N]`
runs [FLARE capa](https://github.com/mandiant/capa) (9.4.0) in a network-denied
Bubblewrap sandbox, builds a **bounded capability inventory** of a PE/ELF/.NET
binary, and emits a deterministic evidence envelope.

Reports COUNTS + a BOUNDED, sorted capability list — never raw disassembly or
match trees.  Any cap that fires is reported in `limitations` and
`capabilities.truncated` is set to `true`; truncation is **never silent**.

## Accepted Input

Any regular non-symlink file.  capa identifies formats automatically.

- **PE32/PE32+, PE .NET, ELF (x86/x86-64/ARM)**: static analysis via vivisect.
- **Unsupported format** (non-zero exit): errors recorded in `errors`, evidence
  published with `status: failed` — not fail-closed with exit 2.
- **Binary where capa matches zero capabilities** (exit 0, empty rules dict):
  evidence published with `status: complete` and an empty inventory — not
  fail-closed.
- **Malformed capa JSON on exit-0**: explicit error string in `errors`, evidence
  published with `status: failed` — never silently promoted to empty inventory.

## Rules-Dir Bind Safety

The default capa-rules directory lives under `/home`
(`~/.local/share/capa-rules`), which `adapter_core.sandbox()`'s
`_RO_INPUT_BLOCKED_ROOTS` mechanism blocks to prevent credential exposure.

To make the rules readable inside the sandbox **without reopening the broad
`/home` exposure**, this adapter adds a **single, explicit, narrowly validated
read-only bind** of exactly the resolved rules directory at
`/tmp/rsdd/capa-rules` (inside the `tmpfs` that `sandbox()` already sets up).
No parent of the rules directory is ever bound.

### Rules-dir validation (`_validate_rules_dir`)

The rules path is validated before any sandbox is launched (fail-closed):

1. **Symlink rejection**: `lstat()` must show `S_ISDIR`, not `S_ISLNK`.  A
   symlink to a valid rules directory is rejected because a symlink can be
   redirected to a sensitive or attacker-controlled path after validation.
2. **Existence and type**: the path must exist and be a regular directory.
3. **Scope guard** (`_rules_scope_guard`): rejects blocked system roots, paths at
   the `/home/<user>` level, and paths shallower than 3 components.  Mirrors
   `venv_root_for()` in `adapter_helpers`.  `--rules ~/` fails before any FS walk.
4. **Plausibility**: requires ≥ 50 `.yml` files OR a known structural subdir
   (`nursery/`, `lib/`, `host-interaction/`, …).  A stray `.yml` does not qualify.

If validation fails, the adapter exits 2 with a descriptive error and publishes
no evidence.  Fix: supply the rules directory directly (not via a symlink), and
ensure it is a real capa-rules checkout (≥ 50 `.yml` files or a structural subdir).

### Rules-dir bind (`_bind_rules`)

The validated, resolved rules directory is bound read-only at
`/tmp/rsdd/capa-rules` using `--dir /tmp/rsdd/capa-rules` + `--ro-bind
<resolved_rules> /tmp/rsdd/capa-rules`, inserted before the trailing `--` in
the bwrap prefix.  capa is then invoked with `-r /tmp/rsdd/capa-rules`.

This binding is local to `corroborate_capa.py` (not promoted to
`adapter_helpers.bind_venv`) because it binds a **data directory**, not a tool
venv, and the mount semantics are different: no `pyvenv.cfg` marker, no
`bin/`-parent check, and the sandbox target path is fixed rather than mirroring
the host path.

## Analysis Sandbox

capa runs inside a hardened Bubblewrap sandbox:

| Property | Value |
|---|---|
| Network access | Denied (`--unshare-net`) |
| Capabilities | All dropped (`--cap-drop ALL`) |
| PID namespace | New (`--unshare-pid`) |
| Filesystem | OS runtime dirs (`/usr`, `/bin`, `/lib`, …) + capa pipx venv read-only + `/tmp/rsdd/capa-rules` read-only; `/etc/passwd` and `/etc/group` bound read-only for vivisect uid/gid resolution; no home, /run, /etc credentials, or user data exposed |
| Signal | `--die-with-parent` — sandbox killed on parent exit |

The capa pipx venv (`~/.local/share/pipx/venvs/flare-capa`) is validated and
bound read-only via `adapter_helpers.bind_venv`; no venv content is written.
`/etc/passwd` and `/etc/group` are bound read-only via `etc_ro_bind_try`
because vivisect calls `getpass.getuser()` → `pwd.getpwuid()`.

## capa JSON Output

capa is invoked with `-j` (JSON output mode) and `-r <rules_dir>`.  The JSON
is written to stdout, captured to `engine/stdout.txt`.  It is read back with
`O_NOFOLLOW` + `lstat`/`S_ISREG` (TOCTOU-safe, symlink-safe) before being
parsed.

## Evidence Schema (`capa-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"capa-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.source` | Source path, byte size, sha256 |
| `input.staged` | Staged logical path, byte size, sha256 |
| `isolation.launcher` | bwrap path, size, sha256 |
| `isolation.profile` | `bubblewrap-capa-offline` profile with `network_access: false`, `target_execution: false` |
| `capabilities.argv` | Inside-sandbox capa argv (canonical, deterministic) |
| `capabilities.tool` | capa path, size, sha256 |
| `capabilities.capa_version` | Version string from `capa --version` |
| `capabilities.rules_path_digest` | `sha256:` digest of sorted `.yml` rule file **paths** (not contents) in the rules directory; named `rules_path_digest` to make path-only semantics explicit |
| `capabilities.caps` | Active caps: `max_capabilities`, `timeout` |
| `capabilities.total_count` | Total capabilities capa matched |
| `capabilities.total_sampled` | Entries in the bounded capability list |
| `capabilities.truncated` | `true` when any cap fired (capability count or run-level) |
| `capabilities.items` | Bounded, sorted list of capability records (see below) |
| `limitations` | Static disclaimers + any cap-trip strings |
| `errors` | Tool-level errors (timeout, non-zero exit, output cap, malformed JSON) |

### Capability record (per item in `capabilities.items`)

| Field | Content |
|---|---|
| `name` | capa rule name (the matched rule's human-readable name) |
| `namespace` | capa rule namespace (e.g. `host-interaction/file-system/write`) |
| `attack_ids` | List of ATT&CK technique IDs matched by this rule (may be empty) |
| `mbc_ids` | List of MBC behavior IDs matched by this rule (may be empty) |
| `match_count` | Number of distinct locations capa matched this rule |

## Caps and Truncation Contract

All caps are visible when they fire: a human-readable limitation string is
appended to `limitations` and `capabilities.truncated` is set to `true`.
**Truncation is never silent.**

| Cap | Flag | Default |
|---|---|---|
| Capability count | `--max-capabilities` | 500 |
| Wall-clock timeout | `--timeout` | 300 s |

- **Capability cap**: when the total number of matched capabilities exceeds
  `max_capabilities`, the `items` list is bounded to `max_capabilities` entries
  sorted by `(namespace, name)`.  The limitation string
  `"inventory truncated: capability cap N reached (total_count=M)"` is appended.
- **Run-level caps** (timeout, output-cap, process-cap): when
  `adapter_core.run_bounded` fires a resource cap, `run_truncation` maps it to
  `capabilities.truncated: true` and a limitation string.  The fired cap is also
  present in `errors` (e.g. `"timeout"`).

## Determinism

For the same input binary, capa installation, and rules directory,
`capa-evidence.v1.json` is byte-reproducible across independent invocations.
The canonical capa argv uses the inside-sandbox path (`/tmp/rsdd/capa-rules`,
`/tmp/rsdd/work/input/binary.bin`), which is fixed regardless of the host
output directory name.

`capabilities.items` is sorted by `(namespace, name)` before any cap is
applied, ensuring identical order across runs.  `capabilities.rules_path_digest`
(a path-name hash, not a content hash) is stable for the same rules checkout.

## Output Layout

```
output-dir/
  capa-evidence.v1.json      # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt               # capa JSON output (raw)
    stderr.txt               # capa informational log / errors
  input/
    binary.bin               # staged copy of input (mode 0400)
```

## Safety Invariants

- `stage_file()` opens the input with `O_NOFOLLOW`; symlink inputs are rejected.
- `_read_stdout_json()` opens `stdout.txt` with `O_NOFOLLOW` + `lstat`/`S_ISREG`;
  symlinks planted by a malicious binary are rejected with `CapaError`.
- A before/after `fstat` detects TOCTOU modification of `stdout.txt` while reading.
- `_validate_rules_dir()` applies four guards: symlink reject, type check, scope
  guard (no blocked roots or `/home/<user>`-level paths; mirrors `venv_root_for()`),
  and plausibility (≥ 50 `.yml` files or a known structural subdir).
- `_bind_rules()` binds ONLY the exact resolved rules directory; no parent is bound.
- Output directory must not pre-exist; `renameat2 RENAME_NOREPLACE` ensures
  atomic, collision-safe publication.
- On any fatal error, staging directories are cleaned up; the destination is
  never partially published.
- The capa pipx venv is bound read-only; no analysis artifact persists in the
  tool tree.
- `/etc/passwd` and `/etc/group` are bound read-only (for vivisect `getpwuid`);
  no other credential or home-directory paths are exposed.
