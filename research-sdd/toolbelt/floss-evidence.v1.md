# `floss-evidence.v1`

`corroborate-floss.sh --input <binary> --output <new-out-dir> [caps]` (a compatibility shim over
`rsdd corroborate floss`, see "The Go port" below) runs
[FLOSS](https://github.com/mandiant/flare-floss) (FLARE Labs Obfuscated String
Solver v3.1.1) in a network-denied Bubblewrap sandbox, builds a **bounded
obfuscated-string inventory** of a PE/ELF binary, and emits a deterministic
evidence envelope.

Reports COUNTS + a BOUNDED, digested sample of extracted strings — never an
unbounded raw dump.  Any cap that fires is reported in `limitations` and
`strings.truncated` is set to `true`; truncation is **never silent**.

## Accepted Input

Any regular non-symlink file.  FLOSS identifies formats internally.

- **PE32/PE32+**: full analysis — static, stack, tight, and decoded strings.
- **ELF and other formats**: static strings only; floss exits non-zero for the
  analysis phase; the exit is recorded as an error and evidence is published with
  `status: failed`.
- **Binary with no detectable strings** (exits 0, no JSON output): evidence is
  published with `status: complete` and an empty inventory — NOT fail-closed.
- **Tool error** (non-zero exit): errors recorded in `errors`; evidence published.

## Analysis Sandbox

floss runs inside a hardened Bubblewrap sandbox:

| Property | Value |
|---|---|
| Network access | Denied (`--unshare-net`) |
| Capabilities | All dropped (`--cap-drop ALL`) |
| PID namespace | New (`--unshare-pid`) |
| Filesystem | OS runtime dirs (`/usr`, `/bin`, `/lib`, …) + floss pipx venv read-only; `/etc/passwd` and `/etc/group` bound read-only for uid/gid resolution; no home, /run, /etc credentials, or user data exposed |
| Signal | `--die-with-parent` — sandbox killed on parent exit |

The floss pipx venv (`~/.local/share/pipx/venvs/flare-floss`) is bound
read-only inside the sandbox so that the tool can execute; no venv content is
written.

### Venv bind validation

`bind_venv` (Go: `core/adapter/helpers.BindVenv`) validates the floss venv root before binding:

- Resolves symlinks (`os.path.realpath`) so wrapper scripts at shallow system
  paths (e.g. `~/bin/floss` where venv root = `~`) are detected and rejected.
- Shape check (pure, no FS): `str(root)` not in a blocked-exact set; `/home/<user>`
  (3 parts) rejected because it requires `>= 4` parts; generic `>= 3` parts.
- FS marker: `pyvenv.cfg` must exist in the resolved venv root.
- Belt: venv root must not equal the real home directory.

If the guard fails, the adapter exits 2 with a descriptive error and publishes
no evidence.  Fix: point `RSDD_FLOSS` at the venv's `bin/floss` directly.

A wall-clock timeout (`--timeout`, default 120 s) is enforced by
`run_bounded` (Go: `core/proc.Run`), which kills the bwrap process group on breach.

## floss JSON Output

floss is invoked with `-j` (JSON output mode).  The JSON is written to stdout,
captured to `engine/stdout.txt`.  It is read back with `O_NOFOLLOW` + `lstat`/
`S_ISREG` (TOCTOU-safe, symlink-safe) before being parsed.

If floss exits 0 but produces **empty stdout** (no strings found in the
binary), the adapter publishes a `status: complete` empty inventory.

If floss exits 0 but stdout is **non-empty and not valid JSON** (malformed
tool output), the adapter records an explicit error string in `errors` and
publishes `status: failed` — this is never silently promoted to an empty
`status: complete` inventory.

## Evidence Schema (`floss-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"floss-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.source` | Source path, byte size, sha256 |
| `input.staged` | Staged logical path, byte size, sha256 |
| `isolation.launcher` | bwrap path, size, sha256 |
| `isolation.profile` | `bubblewrap-floss-offline` profile with `network_access: false`, `target_execution: false` |
| `strings.argv` | Inside-sandbox floss argv (canonical, deterministic) |
| `strings.tool` | floss path, size, sha256 |
| `strings.floss_version` | Version string from `floss --version` |
| `strings.caps` | Active caps: `max_strings`, `max_string_len`, `timeout` |
| `strings.static_strings` | `{count, sampled, truncated, strings: [{offset, encoding, value, sha256}]}` |
| `strings.stack_strings` | Same structure |
| `strings.tight_strings` | Same structure |
| `strings.decoded_strings` | Same structure |
| `strings.total_count` | Sum of all string counts across categories |
| `strings.total_sampled` | Sum of all sampled entries across categories |
| `strings.truncated` | `true` when any cap fired (string count or length) |
| `limitations` | Static disclaimers + any cap-trip strings |
| `errors` | Tool-level errors (timeout, non-zero exit, output cap) |

## Caps and Truncation Contract

All caps are visible when they fire: a human-readable limitation string is
appended to `limitations` and `strings.truncated` (and the per-category
`truncated` flag) is set to `true`.  **Truncation is never silent.**

| Cap | Flag | Default |
|---|---|---|
| Total strings sampled | `--max-strings` | 2 000 |
| Per-string value length | `--max-string-len` | 256 characters |
| Wall-clock timeout | `--timeout` | 120 s |

- **String count cap**: when `total_sampled` reaches `max_strings`, no further
  strings are sampled from any category.  The limitation string
  `"inventory truncated: string cap N reached"` is appended to `limitations`.
- **String length cap**: when any string value exceeds `max_string_len`, it is
  truncated to that length before hashing.  The sha256 digest is of the
  (possibly truncated) value.  The limitation string
  `"inventory truncated: string-length cap N reached"` is appended once.
- **Per-category `truncated`**: each category records `truncated: true`
  independently when `count > sampled` for that category.
- **Run-level caps** (`--timeout`, output-cap, process-cap): when
  `adapter_core.run_bounded` fires a resource cap, `run_truncation` maps it to
  `strings.truncated: true` and a limitation string.  The fired cap is also
  present in `errors` (e.g. `"timeout"`).

Any cap that fires sets `strings.truncated: true` via a boolean flag — never
inferred by scanning string values, never silent.

## Determinism

For the same input file and floss installation, `floss-evidence.v1.json` is
byte-reproducible across independent invocations.  The floss JSON output
includes timing fields (`metadata.runtime.*`) that are NOT included in the
evidence JSON.  Timing data appears only in `engine/stdout.txt` and is excluded
from the manifest's identity hash per the manifest contract.

The canonical floss argv (`strings.argv`) uses the inside-sandbox path
(`/tmp/rsdd/work/input/binary.bin`), which is fixed regardless of the host
output directory name.

## Output Layout

```
output-dir/
  floss-evidence.v1.json     # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt               # floss JSON output (raw, may contain timing)
    stderr.txt               # floss informational log / errors
  input/
    binary.bin               # staged copy of input (mode 0400)
```

## Safety Invariants

- The staging copy (`fsx.StageFile`) opens the input with `O_NOFOLLOW`; symlink inputs are rejected.
- The stdout reader (`readStdoutJSON`) opens stdout.txt with `O_NOFOLLOW` + `lstat`/`S_ISREG`;
  symlinks planted by a malicious binary are rejected with a fail-closed error (exit 2).
- A before/after `fstat` detects TOCTOU modification of stdout.txt while reading.
- Output directory must not pre-exist; `renameat2 RENAME_NOREPLACE` ensures
  atomic, collision-safe publication.
- On any fatal error, staging directories are cleaned up; the destination is
  never partially published.
- The floss pipx venv is bound read-only; no analysis artifact persists in the
  tool tree.
- `/etc/passwd` and `/etc/group` are bound read-only (for `getpwuid`); no
  other credential or home-directory paths are exposed.

## The Go port

The tool is now `rsdd corroborate floss` (Go, kit issue #2484, package
`rsdd/internal/corroborate/floss`); `corroborate-floss.sh` is a compatibility
shim that hands every argument over (`--manifest-cli` is optional, accepted and ignored: the manifest steps run in process). Exit codes (0 complete, 1
evidence published with errors, 2 refusal or usage error), stderr lines, the
evidence JSON, `engine/stdout.txt`, `engine/stderr.txt`, the file modes and the
manifest (run times aside) are byte-identical to the former script on every
case of the differential tests, which run the frozen script
(`rsdd/internal/corroborate/floss/testdata/legacy/corroborate_floss.py`) under
Python 3.12 as the oracle: a 3 000-line command-line corpus (usage, help at
several terminal widths, abbreviations, `--opt=value`, integers), a 4 000-input
JSON corpus (the exact `json.loads` messages and positions the script copies
into `errors`) and whole runs against a stand-in floss and the real bwrap. The
differences, all stricter or crash-free:

- A stage directory that already exists (another run in flight, or a leftover)
  is never deleted by the run that failed to create it; the script's cleanup
  removed it.
- A floss executable that fails the venv guard (`tool executable is not inside
  a 'bin/' directory`, a bind scope error) exits 2 with
  `corroborate-floss: <reason>` as this document always promised; the script
  let the exception escape (a traceback, exit 1).
- floss output the script crashes on (a document that is not an object, a
  category that is not an array, entries that are not objects, a non-string
  `string`, a non-numeric `offset`), output that is not UTF-8 JSON text
  (UTF-16/32 included), a lone surrogate, and NaN, Infinity or a float beyond
  the double range end the run with `corroborate-floss: <reason>` and exit 2
  where the script printed a traceback and exited 1 (or published evidence).
- The analysis manifest is built in process by `rsdd` (kit issue #2561; the
  script ran the Python manifest tool with its own interpreter); the integers `--timeout`, `--max-strings` and
  `--max-string-len` keep Python's unbounded range, and beyond 4 300 digits are
  a usage error as in Python 3.12.
- An explicit `--opt=--` value is kept as the text `--` (argparse drops it and
  the script then crashes).
- The `--help` and usage layout follow `COLUMNS` (80 when unset or invalid)
  like argparse's formatter; the terminal size itself is not queried.
