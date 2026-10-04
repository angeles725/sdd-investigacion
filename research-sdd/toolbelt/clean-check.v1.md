# `clean-check.v1`

`clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR]` is a **read-only** instrument that
reports leftovers a run should not leave behind (kit issue #1277, the NO-GARBAGE rule). It lists;
it never deletes, moves, or edits anything (propose-never-apply): the operator or the campaign
decides what to do with each finding.

## What it scans

| Class | Finding line | Rule |
|---|---|---|
| untracked | `GARBAGE untracked <path>` | Every untracked, **non-ignored** file under `--target` (default `.`) that no keep-list glob matches. Listed by `git ls-files --others --exclude-standard`, so `.gitignore`d files are never findings and an untracked directory is expanded to its files. |
| stale temp | `GARBAGE stale-tmp <path> age=<h>h` | Every direct child of `--tmp` (default `${TMPDIR:-/tmp}`) whose name matches `tmp.*` (the `mktemp` default), whose mtime is older than the stale age, and that is owned by the current user. Files and directories both count. `<h>` is whole hours since the entry's own mtime. |
| unpreserved artifact | `UNPRESERVED-ARTIFACT <file> cited by <block>` | Only with a scratchpad configured (kit #1207; see below). A file in the scratchpad whose basename or full path is mentioned by an `.md` block of the target, with no byte-identical copy under `<TARGET>/sources/probes/`: evidence about to be lost. |
| unmanifested script | `UNMANIFESTED-SCRIPT <file>` | Only with a scratchpad configured. A scratchpad script (extension `sh ps1 py java js rb pl bat cmd groovy kts`) whose basename is not the first table cell of any row of a `<TARGET>/sources/probes/**/SCRIPTS-MANIFEST.md`. |

The stale age defaults to **24 h** and is overridden with `--stale-hours N` (a non-negative
decimal integer of at most 9 digits; a leading zero is still decimal, so `08` is 8; anything else
is exit 2; `0` makes every owned `tmp.*` entry stale). Entries owned by another user are never
reported: the instrument must not suggest deleting what the operator cannot delete.

## The keep-list contract

`<TARGET>/.research-sdd/keep.txt` declares untracked files that are deliberately kept.

- One glob per line, relative to the target root (the `--target` directory).
- Blank lines and lines whose first non-blank character is `#` are comments.
- A line may carry a reason: `<glob> # <reason>`; everything from the first ` #` (a space
  followed by `#`) is the reason and is ignored by the matcher.
- Matching uses shell pattern semantics against the path relative to the target: `*` and `?`
  also match `/`, and a glob ending in `/` keeps everything below that directory.
- `keep.txt` itself is never reported.
- The keep-list only suppresses the `untracked` class. It does not apply to `stale-tmp`.

A missing keep-list is the typed line `ABSENT-KEEPLIST <path>`: every untracked file then counts.
It is information, not a finding, and does not change the exit code. The summary always states
how many keep-list entries were applied, so "0 findings" can be told apart from "everything was
kept".

## The session scratchpad

The scratchpad is the one declared place a session may write. It is named by `--scratchpad DIR`,
which wins over the `CLEAN_CHECK_SCRATCHPAD` environment variable (used when set and non-empty).

- **Exempt from the base classes.** An entry at or below the scratchpad is never reported as
  `untracked` or `stale-tmp`.
- **Scanned for lost evidence (kit #1207).** Every regular file in the scratchpad is checked
  against the target's blocks and manifests, producing the two finding classes below.
- **Live directory.** The scratchpad is read while the session keeps writing and deleting in it.
  A file that vanishes mid-walk is benign: GNU `find` runs with `-ignore_readdir_race`; where
  `find` lacks it (BSD), only `No such file or directory` stderr lines are tolerated and any other
  `find` error is still exit 2.

### `UNPRESERVED-ARTIFACT <file> cited by <block>`

A scratchpad file counts as cited when its basename or full path appears in an `.md` block of the
target (tracked or untracked, via `git ls-files -co`) as a whole path component: never a bare
substring, so `run.sh` is not matched by `prerun.sh`. `SCRIPTS-MANIFEST.md` files are excluded as
blocks (a manifest row names a script on purpose: it is the preservation record). The finding is
suppressed when a byte-identical copy (sha256) already sits anywhere under
`<TARGET>/sources/probes/`; such skips are counted in `preserved-copies:`. The remedy is to
preserve the file under `sources/probes/b<N>/` first. Without `sha256sum` or `shasum` the check is
skipped and the typed line `DEGRADED-NO-SHA256 ...` is printed, so a missing hash tool never reads
as "everything preserved".

### `UNMANIFESTED-SCRIPT <file>`

The basename must equal, exactly, the first table cell of some row (backticks and blanks removed,
directory part dropped) of any `SCRIPTS-MANIFEST.md` under `<TARGET>/sources/probes/`. See
`verify-block.sh` for the manifest row format.

### Scratchpad state is never a silent zero

| State | Summary field | Extra line |
|---|---|---|
| not configured | `scratchpad: not set` | none |
| configured, directory missing | `scratchpad: absent` | `ABSENT-SCRATCHPAD <path>` (information, not a finding; exit code unchanged) |
| scanned | `scratchpad: N file(s), blocks-missing-on-disk: B, preserved-copies: P` | findings, if any |

`blocks-missing-on-disk` counts `.md` files that git lists but that are absent from the work tree
(tracked and deleted): they are skipped and counted, never a crash. `preserved-copies` counts
cited scratchpad files skipped because a byte-identical copy is under `sources/probes/`.

## Output and exit codes

Output order: the `ABSENT-KEEPLIST` line (only when `keep.txt` is missing), then the finding lines
(untracked in git order, stale-tmp sorted, then the scratchpad lines: `ABSENT-SCRATCHPAD` or
`DEGRADED-NO-SHA256` when they apply, `UNPRESERVED-ARTIFACT` / `UNMANIFESTED-SCRIPT` per file in
sorted file order), then one summary line. So a clean run with a keep-list
prints exactly one line, the summary; a clean run without a keep-list prints `ABSENT-KEEPLIST` and
the summary.

```
CLEAN-CHECK: clean (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>, scratchpad: <state>)
CLEAN-CHECK: <N> finding(s) (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>, scratchpad: <state>)
```

`<state>` is one of the three scratchpad summary forms above.

| Exit | Meaning |
|---|---|
| 0 | clean (also `-h` / `--help`) |
| 1 | at least one finding |
| 2 | usage error, `--target` absent or not inside a git work tree, `--tmp` absent, or a scan command failed (including the scratchpad `find`, the block listing and a `grep` failure while reading a block) |
| 3 | `DEGRADED`: a tool in the script's `REQUIRED_TOOLS` list (`git find date sort id stat`) is not on `PATH`, or the `sources/probes` manifest scan or probes scan failed; the run stops there with no summary line (the typed `DEGRADED` line goes to stderr). The script header still files scan failures under exit 2; this table documents the code's behaviour, and unifying the two is tracked in kit issue #1659 |

A scan that errors partway is exit 2, never a quiet "clean": both the untracked list (`git ls-files`)
and the `tmp.*` list (`find`) are read with an explicit end marker, and the `sort` ordering step carries
its own, so a truncated or failed `git`, `find` or `sort` cannot read as an empty list. The scan's own
stderr is shown, and a `git rev-parse` failure reports git's reason (for example dubious ownership)
instead of "not a work tree"; stderr noise from a `git rev-parse` that succeeds is ignored (only its stdout is compared).

## Test hook

`CLEAN_CHECK_UID` overrides the uid used for the ownership filter (default `id -u`); the suite
uses it to prove the filter bites without needing a second user.

## Known limits

- A `tmp.*` entry that vanishes between readdir and stat would make `find` fail. Where `find`
  supports `-ignore_readdir_race` (GNU) the scan uses it and the race is benign; where it does not
  (BSD) the `tmp.*` scan still exits 2 loudly on such a race, and a rerun is the remedy. The
  scratchpad scan is the exception: it tolerates `No such file or directory` on BSD (see above).
- Stale age is the entry's own mtime. A directory's mtime moves when a direct child is added or
  removed, so a long-lived directory that is still being written can read as young.
- Only direct children of `--tmp` are examined.
- Stale worktrees, merged branches and `_evidence` retention (also named in #1277) are not
  scanned by v1.
