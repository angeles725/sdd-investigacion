# `unblob-evidence.v1`

`corroborate-unblob.sh --input <image> --output <new-out-dir> [caps]` runs
[unblob](https://github.com/onekey-sec/unblob) (v26.6.4) in a network-denied
Bubblewrap sandbox, builds a **bounded recursive extraction inventory** of a
firmware or opaque-binary image, and emits a deterministic evidence envelope.

Reports STRUCTURE only — extracted-entry paths, sizes, sha256 digests, and
recursive depth.  Never emits raw payload bytes or secret values.  Extracted
files are deleted after inventorying; only the evidence envelope is published.

## Accepted Input

Any regular non-symlink file.  unblob identifies formats internally from magic
bytes and heuristics.  Unknown or encrypted content produces an empty inventory
with `status: complete`; a tool error produces `status: failed` with an entry
in `errors`.

## Extraction Sandbox

unblob runs inside a hardened Bubblewrap sandbox:

| Property | Value |
|---|---|
| Network access | Denied (`--unshare-net`) |
| Capabilities | All dropped (`--cap-drop ALL`) |
| PID namespace | New (`--unshare-pid`) |
| Filesystem | OS runtime dirs (`/usr`, `/bin`, `/lib`, …) + unblob pipx venv read-only; extraction dir writable; no home, /run, /etc credentials, or user data exposed |
| Signal | `--die-with-parent` — sandbox killed on parent exit |

The unblob pipx venv (`~/.local/share/pipx/venvs/unblob`) is bound
read-only inside the sandbox so that the tool can execute; no venv content is
written.  The extraction output directory is bound writably at a fixed sandbox
path (`/tmp/rsdd/extract`) and deleted from the host before publication —
payload bytes never appear in the published output.

### Venv bind validation

`adapter_helpers.bind_venv` validates the unblob venv root before binding:

- Resolves symlinks (`os.path.realpath`) so wrapper scripts at shallow system
  paths (e.g. `~/bin/unblob` where venv root = `~`) are detected and rejected.
- Shape check (pure, no FS): `str(root)` not in a blocked-exact set; `/home/<user>`
  (3 parts) rejected because it requires `>= 4` parts; generic `>= 3` parts.
- FS marker: `pyvenv.cfg` must exist in the resolved venv root.
- Belt: venv root must not equal the real home directory.

The extraction directory is a writable adapter-controlled temp dir that may
live under `/home` (the output parent); it deliberately bypasses the blocked-
roots check and is validated by `sandbox_path.startswith("/tmp/rsdd/")` and
an `lstat` non-symlink/is-directory check instead.

If the guard fails, the adapter exits 2 with a descriptive error and publishes
no evidence.  Fix: point `RSDD_UNBLOB` at the venv's `bin/unblob` directly.

A wall-clock timeout (`--timeout`, default 120 s) is enforced by
`adapter_core.run_bounded()`, which kills the bwrap process group on breach.
When the timeout fires, `run_truncation` sets `extraction.truncated: true` and
records a limitation — truncation is never silent.

## Post-Extraction Inventory Walk

After extraction, every file under the extraction root is walked with
`os.walk(followlinks=False)` and lstat (no symlink follows).  For each
regular file, sha256 is computed via an `O_NOFOLLOW`-guarded open with
before/after fstat TOCTOU protection.

Safety rules during the walk:
- **Symlinks**: skipped; path recorded in `errors`.
- **Special files** (devices, pipes, sockets): skipped; recorded in `errors`.
- **Hardlinked files** (`st_nlink > 1`): skipped; recorded in `errors`.
- **Path traversal** (`..` components or absolute paths): **fail-closed** — the
  entire adapter exits 2 and no evidence is published.
- **unblob metadata report** (`unblob-report.json` at the extraction root): excluded
  from the inventory (read for task counts; not an extracted payload).

## Evidence Schema (`unblob-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"unblob-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.source` | Source path, byte size, sha256 |
| `input.staged` | Staged logical path, byte size, sha256 |
| `isolation.launcher` | bwrap path, size, sha256 |
| `isolation.profile` | `bubblewrap-unblob-offline` profile with `network_access: false`, `target_execution: false` |
| `extraction.argv` | Inside-sandbox unblob argv (canonical, deterministic) |
| `extraction.tool` | unblob path, size, sha256 |
| `extraction.caps` | Active caps: `max_entries`, `max_total_bytes`, `max_depth`, `timeout` |
| `extraction.entries` | Sorted list of `{path, size, sha256, depth, type}` for regular files |
| `extraction.entry_count` | Count of inventoried entries |
| `extraction.total_size_bytes` | Sum of inventoried file sizes |
| `extraction.truncated` | `true` when any cap fired during the walk |
| `extraction.unblob_report_tasks` | Number of tasks in unblob's internal report |
| `limitations` | Static disclaimers + any cap-trip strings (`"inventory truncated: entry cap N reached"`, etc.) |
| `errors` | Tool-level errors (timeout, non-zero exit) + per-file walk issues (symlinks, hardlinks, etc.) |

## Caps and Truncation

All caps are visible when they fire: a human-readable limitation string is
appended to `limitations` and `extraction.truncated` is set to `true`.
Truncation is never silent.

**Run-level caps** (`--timeout`, output-cap, process-cap): when
`adapter_core.run_bounded` fires a resource cap, `run_truncation` ORs the
truncated flag into `extraction.truncated` and appends a limitation string.
The fired cap token (e.g. `"timeout"`) is also present in `errors`.

The **depth cap** fires when the inventory walk encounters a directory whose
files would be at depth > `max_depth` and prunes its subdirectories.  The
limitation is recorded the first time a non-empty subdirectory list is pruned
at the boundary (not when files are encountered beyond the cap, because the
pruning prevents `os.walk` from descending further).  With empty input or
unrecognized formats, unblob exits 0 with an empty extraction; the adapter
publishes a complete evidence envelope with `status: complete` and 0 entries
rather than failing closed.

| Cap | Flag | Default |
|---|---|---|
| Inventory entries | `--max-entries` | 10 000 |
| Total inventoried bytes | `--max-total-bytes` | 256 MiB |
| Recursive extraction depth | `--max-depth` | 10 |
| Wall-clock timeout | `--timeout` | 120 s |

## Determinism

For the same input file and unblob installation, `unblob-evidence.v1.json` is
byte-reproducible across independent invocations.  Timing fields
(`run.started_at`, `run.ended_at`, `run.duration_ms`) appear only in
`analysis-manifest.v1.json` and are excluded from the manifest's identity hash
per the manifest contract.

## Output Layout

```
output-dir/
  unblob-evidence.v1.json      # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt                 # unblob console output
    stderr.txt                 # unblob stderr
  input/
    firmware.bin               # staged copy of input (mode 0400)
```

Extracted payload files are NOT published.  They are deleted after inventory.

## Safety Invariants

- symlinks, special files, and hardlinks in the extraction tree are skipped
  and recorded as errors — never silently ignored, never followed.
- Path traversal in extracted paths (`..` or absolute) triggers an immediate
  fail-closed error before any publication.
- All caps are enforced before walk completion and are visible in the envelope.
- Extracted payload bytes never appear in the published evidence output.
- Publication uses `renameat2 RENAME_NOREPLACE` (atomic, no-replace).
- On any error, only owned staging directories are removed; the destination is
  never partially published.
