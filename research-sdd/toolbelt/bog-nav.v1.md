# `bog-nav.v1`

`bog-nav.sh --input <config.bog> --output <evidence.json>`
reads a Niagara N4 station `config.bog` (a ZIP containing `file.xml`, or bare
plaintext XML such as `platform.bog`) and emits a deterministic key-sorted JSON
evidence envelope containing the component tree structure, link topology, and
module prefix-map.

Uses only Python stdlib; no external tools or network access required.
Read-only with respect to `.bog` files: writes only the evidence JSON at `--output`;
no `.bog` writes, no subprocesses, no execution of station logic.

## Trust Boundary and Accepted Input

Any regular, non-symlink `.bog` file containing a Niagara N4 BOG-XML graph.

- **Symlink input**: rejected via `O_NOFOLLOW`; exit 2, no evidence emitted.
- **Non-regular file** (FIFO, device, directory): rejected via `S_ISREG` check after
  `O_NONBLOCK` open (no blocking wait for a FIFO writer); exit 2, no evidence emitted.
- **Absent or unreadable file**: exit 2, no evidence emitted.
- **ZIP bog with `file.xml` > 32 MiB inflated**: `status: failed`, `truncated: true`,
  exit 1; ZIP inflation is bounded at 32 MiB by a LENGTH-BOUNDED read
  (`f.read(CAP + 1)`); `getinfo().file_size` is never used as the bound (forged
  central-directory headers defeat that check — PR5/zip-bomb lesson).
- **ZIP entry read failure** (corrupted deflate stream, CRC mismatch, encrypted entry,
  or unsupported compression method): `status: failed`; exit 1; JSON emitted with
  `errors` populated.  The entry-read block is wrapped in `except Exception` so no
  zip-level error can escape as an unhandled traceback (BLOCKER fix).
- **Non-XML, non-ZIP content**: `status: failed`; exit 1; JSON emitted with
  `errors` populated.
- **Valid bog**: `status: complete`; exit 0; `components`, `links`, and
  `summary` populated.
- **Valid bog with no components** (e.g. `platform.bog` or an empty station):
  `status: complete`; exit 0; `components: []`, `summary.components: 0`.
  This is the anti-silent-zero state — proves the instrument looked.

## SECRETS DISCIPLINE

A station `config.bog` may contain credential values, encoded keys, and
password fields stored in component slots.  This wrapper emits STRUCTURE only:
component paths, types, handles, and link topology.  **Slot values are never
emitted.**  The `components` array carries `handle`, `path`, `type`, and
`module` only.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Complete — bog parsed, evidence emitted (components may be 0) |
| 1 | Parse error — ZIP cap exceeded, no `file.xml`, or malformed content (`status:failed` JSON emitted) |
| 2 | I/O error — absent/unreadable input, symlink input, non-regular file, or output write failure (no JSON emitted) |

## Evidence Schema (`bog-nav.v1.json`)

| Field | Content |
|-------|---------|
| `schema` | `"bog-nav.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.format` | `"zip-xml"` (ZIP containing `file.xml`), `"plaintext-xml"` (bare XML), or `"unknown"` |
| `input.sha256` | SHA-256 hex digest of the full input file |
| `input.size_bytes` | Total byte size of the input file |
| `summary.components` | Count of parsed components (0 for an empty or non-component bog) |
| `summary.links` | Count of parsed link records |
| `summary.prefixes` | Module prefix-to-module-name map declared in the bog header (e.g. `{"b": "baja", "c": "control"}`) |
| `components` | Array of `{"handle", "module", "path", "type"}` records — structure only, no slot values |
| `links` | Array of `{"link_name", "source", "src_resolved", "target"}` records; `source` and `target` are `<path>.<slot>` strings; `src_resolved: true` when the sourceOrd handle was resolved to a path |
| `errors` | Parse-level error strings; non-empty when `status: failed`; may also be non-empty when `status: complete` and a cap fired (component or link list truncated — truncation is a visibility note, not a failure) |
| `limitations` | Static disclaimer strings |
| `truncated` | `true` when any cap fired (inflate cap, component cap, or link cap) |

## Anti-Silent-Zero (§7 Compliance)

Three states are always distinguishable:

| State | Exit | JSON | Indicator |
|-------|------|------|-----------|
| absent-or-unreadable | 2 | none | file missing, unreadable, non-regular, or symlink; error on stderr |
| parse-error | 1 | `status: "failed"`, `errors` non-empty | ZIP cap exceeded, no `file.xml`, or malformed content |
| valid | 0 | `status: "complete"`, `errors: []` | bog parsed successfully; `components` may be 0 |

A bog with zero components (`platform.bog`, empty station) is distinct from an
absent or parse-failed input: it exits 0 with `status: complete` and
`summary.components: 0`.  This proves the instrument looked.

## Caps and Truncation

| Cap | Value | Trigger |
|-----|-------|---------|
| `_MAX_BOG_INFLATE` | 32 MiB | ZIP `file.xml` inflate size |
| `_MAX_COMPONENTS` | 50 000 | Component list length |
| `_MAX_LINKS` | 20 000 | Link list length |

When `_MAX_BOG_INFLATE` fires, the tool returns `status: failed` and
`truncated: true` without attempting to parse the partial XML.  Component and
link caps emit a truncation note in `errors` and set `truncated: true`.

**Zip-bomb protection**: the bounded read uses
`with z.open("file.xml") as f: data = f.read(_MAX_BOG_INFLATE + 1)` followed by
`if len(data) > _MAX_BOG_INFLATE: ...`.  The `getinfo().file_size` field in the
ZIP central directory is intentionally ignored — a crafted header can claim any
size.

## Non-Goals

- Slot values, action flags, and credential fields are never published (secrets
  discipline).
- Interactive query subcommands (`tree`, `slot`, `links`, `diff`, etc.) are not
  provided; this wrapper emits a single structural evidence snapshot.
- Nested `.bog` archives (a `.dist` station backup containing a `config.bog`)
  are not supported; only the outermost ZIP level is inspected.
- No `.bog` writes are performed.

## Output Layout

```
evidence.json      # key-sorted JSON (this schema)
```

The output path must not already exist (symlinks and pre-existing files are
refused with exit 2 via `O_CREAT|O_EXCL|O_NOFOLLOW`).

## Invocation Example

```bash
bog-nav.sh --input config.bog --output bog-evidence.json
```
