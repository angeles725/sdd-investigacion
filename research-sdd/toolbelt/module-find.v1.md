# module-find.v1 — Schema Reference

## Invocation

```sh
module-find.sh <src_root> [--output <path>]
```

`<src_root>` must be a non-symlink directory (the root of a Niagara N4 module
Java source tree).  `--output` writes JSON evidence to `<path>`; without the
flag the JSON is written to stdout.

## One-Line Bounds

Read-only; stdlib only; 2 MiB per-file byte cap with `files_byte_capped` count
visibility; 5 000-file cap with `truncated:true` visibility; no symlink followed
out of root (realpath containment); no writes to input tree.

## Trust Boundary & Accepted Input

| Input | Accepted | Rejected |
|---|---|---|
| `src_root` | non-symlink, non-empty, regular directory | symlink (exit 2); absent (exit 2); non-directory file (exit 2) |
| `--output` path | new, non-symlink, non-existent file | symlink target (exit 2); pre-existing file (exit 2, O_CREAT\|O_EXCL) |
| `.java` source files | regular files only (S_ISREG) | symlinks, devices (skipped silently); **unreadable files → status:failed, exit 1** |
| Subdirectories | non-symlink dirs inside root | dot-dirs (pruned); dirs resolving outside root via realpath (pruned) |

## Evidence Schema

| Field | Type | Content |
|---|---|---|
| `schema` | string | `"module-find.v1"` |
| `status` | string | `"complete"` or `"failed"` |
| `root` | string | Absolute path of the scanned root |
| `scanned` | integer | Number of `.java` files processed |
| `truncated` | boolean | `true` when the 5 000-file cap fired; not all files were scanned |
| `files_byte_capped` | integer | Number of files whose content was truncated by the per-file byte cap; `0` when no file exceeded the cap |
| `slots` | array | `@NiagaraProperty` declarations; see slot object below |
| `actions` | array | `@NiagaraAction` declarations; see action object below |
| `extends` | object | `{ClassName: SuperclassName}` map extracted from `class X extends Y` |
| `errors` | array | Error strings for unreadable files and extends-key collisions; empty on clean scan |

### Slot object

| Field | Content |
|---|---|
| `class` | Java class name (filename without `.java`) |
| `slot` | Slot name from `name = "..."` |
| `type` | Slot type string from `type = "..."` (empty string if absent) |
| `flags` | Flags expression string from `flags = ...` (empty string if absent); compound expressions like `Flags.A | Flags.B` are captured in full |
| `min` | Float minimum value from `BFacets.MIN / BDouble.make(...)` facet, or `null` |

### Action object

| Field | Content |
|---|---|
| `action` | Action name from `name = "..."` |
| `class` | Java class name |
| `flags` | Flags expression string from `flags = ...` (empty string if absent); compound expressions like `Flags.A | Flags.B` are captured in full |

## Three-State Honesty

| State | `scanned` | `slots` | `status` | Exit code |
|---|---|---|---|---|
| absent / symlink / non-dir root | — | — | no JSON | 2 |
| empty source tree (no `.java` files) | `0` | `[]` | `complete` | 0 |
| populated tree, no annotations found | `N > 0` | `[]` | `complete` | 0 |
| annotations found | `N > 0` | non-empty | `complete` | 0 |
| walk error during scan (e.g. unreadable file) | `N ≥ 0` | partial | `failed` | 1 |

The `scanned` field is always present on exit 0 or exit 1 and proves the
instrument looked.  A count of 0 means the tree was genuinely empty (no
`.java` files), not that the tool failed to traverse it.

## Caps / Truncation

| Cap | Value | Visibility |
|---|---|---|
| Files scanned | 5 000 | `truncated: true` in JSON; `scanned` shows how many were processed |
| Bytes read per file | 2 MiB | `files_byte_capped` count incremented per over-cap file; `0` when no file exceeded the cap |

## Report-All vs. Dedup

Every annotation occurrence is emitted as a separate record (report-all
semantics).  The `extends` map is keyed by bare class name (filename without
`.java`): if two files in different packages share the same class name, the
first-seen entry wins and a collision warning is appended to `errors`.

## Parser: Annotation Forms Recognised

The paren-balance join handles multi-line annotation bodies.  A `//` comment
containing `(` may inflate the depth counter and cause extra lines to be
absorbed into the buffer; the per-fragment split correctly extracts all
`@NiagaraProperty(` / `@NiagaraAction(` spans from the wider buffer regardless.

After the balanced buffer is collected, it is **split into per-annotation
fragments** using `@NiagaraProperty(` and `@NiagaraAction(` as split tokens.
One record is emitted per fragment.  This handles both forms present in the
field:

1. **Bare form**: `@NiagaraProperty(name = "slot", type = "T", flags = Flags.F)`
   — one fragment, one record.
2. **Container form**: `@NiagaraProperties({@NiagaraProperty(...), @NiagaraProperty(...)})`
   — N fragments, N records (all property siblings extracted, not only the first).
3. **Action container form**: `@NiagaraActions({@NiagaraAction(...), @NiagaraAction(...)})`
   — same per-fragment split; all action siblings extracted.

Both forms are extracted for `name`, `type`, `flags`, and (when present)
`BFacets.MIN / BDouble.make(...)` minimum value.

## Non-Goals

- Does not execute any Java compiler or runtime.
- Does not resolve slot types across inheritance chains.
- Does not scan JARs or compiled `.class` files; source only.
- Does not emit writers (`.set(...)` / `setX(...)`) or ORD literals.
- Does not produce diffs between two source versions.

## Output Layout

Without `--output`: key-sorted JSON written to stdout, one object per
invocation.

With `--output <path>`: same JSON written atomically to `<path>` via
`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` (refuses to overwrite existing files or
follow symlinks).  Exit 2 if the write fails.
