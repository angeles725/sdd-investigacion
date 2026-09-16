# palette-lexicon.v1 — Evidence Schema

## Invocation

```
palette-lexicon-agents.sh --input <module-dir> --output <evidence.json>
```

`<module-dir>` is the top-level directory for one N4 module (non-symlink, non-file).
It contains artifact subdirs, each of which must have an `extracted/` subdirectory.

## One-Line Bounds

Input directory: max 500 artifact subdirs. Per-artifact reads: `module.palette` capped at
16 MiB; each `*.lexicon` file capped at 4 MiB; `META-INF/module.xml` capped at 1 MiB.

## Trust Boundary & Accepted Input

| Property | Requirement |
|---|---|
| `--input` | Non-symlink directory; stripped of trailing separator before `lstat` |
| `--output` | New file path; `O_CREAT\|O_EXCL\|O_NOFOLLOW` — refuses pre-existing files and symlinks |
| Artifact subdirs | Non-symlink directories inside `--input`; symlink subdirs skipped |
| Files inside `extracted/` | Read with `O_RDONLY\|O_NOFOLLOW\|O_NONBLOCK`; regular-file check via `fstat` |
| Containment | `realpath` check on every subpath; paths resolving outside `--input` are skipped |

The tool is read-only. It never writes to the module directory.

## Evidence Schema

Root-level fields of the emitted JSON:

| Field | Type | Content |
|---|---|---|
| `schema` | string | `"palette-lexicon.v1"` |
| `status` | string | `"complete"` or `"failed"` |
| `artifacts` | array | One entry per artifact subdir scanned (see below) |
| `summary` | object | Aggregated counts across all artifacts (see below) |
| `errors` | array | XML parse error messages; non-empty when `status:"failed"` |
| `limitations` | array | Static capability limits (read caps, unsupported formats) |
| `truncated` | bool | `true` when artifact subdirs were capped at 500 |

### Per-artifact object (`artifacts[*]`)

| Field | Type | Content |
|---|---|---|
| `artifact` | string | Artifact subdirectory name |
| `palette_count` | integer | Number of `<p>` elements with at least one of `n`/`t`/`m` attributes in `module.palette` |
| `palette_present` | boolean | `true` when `module.palette` was found and readable; `false` when absent/unreadable (§7 presence signal) |
| `lexicon_files_seen` | integer | Count of `*.lexicon` files found recursively under `extracted/`; 0 means no lexicon file present (§7 absent-vs-empty distinction) |
| `lexicon_keys` | integer | Total valid `key=value` lines across all `*.lexicon` files (alias for `keys_examined`) |
| `keys_examined` | integer | Same as `lexicon_keys`; present for §7 anti-silent-zero proof |
| `duplicate_bare_keys` | object | `{relpath: {key_name: occurrence_count}}` where `relpath` is the path of the `.lexicon` file relative to `extracted/` (so same-basename files in different subdirs remain distinct keys); keys appearing more than once within that single `.lexicon` file only (per-file duplicate-bare-key hazard); a key that appears in multiple files but only once per file is NOT reported |
| `duplicate_bare_keys_count` | integer | Total number of (file, key) within-file dup pairs across all lexicon files for this artifact |
| `agents` | array | Agent registrations from `META-INF/module.xml` (see below) |
| `agents_count` | integer | Number of agent registrations |
| `module_xml_present` | boolean | `true` when `META-INF/module.xml` was found and readable; `false` when absent/unreadable (§7 presence signal) |

### Agent object (`artifacts[*].agents[*]`)

| Field | Type | Content |
|---|---|---|
| `type_name` | string | `name=` attribute of the enclosing `<type>` element |
| `type_class` | string | `class=` attribute of the enclosing `<type>` element |
| `on_types` | array | `type=` attribute values from `<on>` child elements |

### Summary object (`summary`)

| Field | Type | Content |
|---|---|---|
| `artifacts_scanned` | integer | Number of artifact subdirs with an `extracted/` directory |
| `palette_entries` | integer | Total `<p>` property-slot elements across all artifacts |
| `lexicon_keys` | integer | Total valid `key=value` lines across all artifact lexicons |
| `keys_examined` | integer | Same as `lexicon_keys`; §7 proof that the lexicon parser ran |
| `duplicate_bare_keys` | integer | Total within-file dup (file, key) pairs across all artifacts |
| `agents` | integer | Total agent registrations across all artifacts |

## Three-State Honesty (§7)

| State | Condition | Observable |
|---|---|---|
| absent-input | `--input` path not found, is a symlink, or is not a directory | exit 2; no JSON produced |
| empty-input | Valid module dir with no artifact subdirs having `extracted/` | exit 0; `status:"complete"`; `artifacts_scanned:0`; `keys_examined:0` |
| no-match | Artifacts scanned; none had palette entries, lexicon keys, or agents | exit 0; `status:"complete"`; `artifacts_scanned:N`; all counts zero; `keys_examined` present |

Per-artifact presence signals distinguish absent vs empty vs no-match for each file type:

- `lexicon_files_seen:0` — no `*.lexicon` files found recursively under `extracted/`
- `lexicon_files_seen:N, keys_examined:0` — lexicon files found but all are either blank/comment-only or unreadable; unreadable files appear in `errors[]` (§7 absent-not-traversable distinct from empty)
- `palette_present:false` — `module.palette` absent or unreadable
- `module_xml_present:false` — `META-INF/module.xml` absent or unreadable

`keys_examined` distinguishes "lexicon present but no key lines" from "lexicon file absent":
when lexicon files exist and are readable, `keys_examined` equals the number of valid
`key=value` lines across all of them. A count of 0 that cannot prove the parser ran is
a bug, not a finding.

## Caps / Truncation

| Cap | Limit | Visibility |
|---|---|---|
| Artifact subdirs | 500 | `truncated:true` at root level |
| `module.palette` | 16 MiB | Error entry in `errors[]`; truncated XML cannot be partially parsed — `palette_count` is 0 when truncation causes parse failure; a pathological XML tree can still exceed available memory during parse — `MemoryError` is caught and yields `status:failed` |
| `*.lexicon` per file | 4 MiB per file | Error entry in `errors[]`; `keys_examined` may be partial |
| `META-INF/module.xml` | 1 MiB | Error entry in `errors[]`; `agents` may be partial |

## Non-Goals

- JAR fallback: when no `extracted/` directory exists for an artifact, the artifact is
  skipped. JAR reading is not implemented.
- Backslash-continuation: multi-line property values (Java `.properties` continuation
  lines ending with `\`) are not joined. Each line is parsed independently.
- Value emission: lexicon values are never read past the first `=` separator (secrets discipline).
- Write operations: this tool never modifies the module directory or its contents.

## Output Layout

```json
{
  "artifacts": [
    {
      "agents": [
        {
          "on_types": ["baja:Component"],
          "type_class": "com.example.alarm.BAlarmSource",
          "type_name": "AlarmSource"
        }
      ],
      "agents_count": 1,
      "artifact": "alarm-rt",
      "duplicate_bare_keys": {
        "alarm-rt.lexicon": {
          "alarm.displayName": 2
        }
      },
      "duplicate_bare_keys_count": 1,
      "keys_examined": 5,
      "lexicon_files_seen": 1,
      "lexicon_keys": 5,
      "module_xml_present": true,
      "palette_count": 3,
      "palette_present": true
    }
  ],
  "errors": [],
  "limitations": ["..."],
  "schema": "palette-lexicon.v1",
  "status": "complete",
  "summary": {
    "agents": 1,
    "artifacts_scanned": 1,
    "duplicate_bare_keys": 1,
    "keys_examined": 5,
    "lexicon_keys": 5,
    "palette_entries": 3
  },
  "truncated": false
}
```
