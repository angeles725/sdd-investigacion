# `clean-check.v1`

`clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]` is a **read-only** instrument that
reports leftovers a run should not leave behind (kit issue #1277, the NO-GARBAGE rule). It lists;
it never deletes, moves, or edits anything (propose-never-apply): the operator or the campaign
decides what to do with each finding.

## What it scans

| Class | Finding line | Rule |
|---|---|---|
| untracked | `GARBAGE untracked <path>` | Every untracked, **non-ignored** file under `--target` (default `.`) that no keep-list glob matches. Listed by `git ls-files --others --exclude-standard`, so `.gitignore`d files are never findings and an untracked directory is expanded to its files. |
| stale temp | `GARBAGE stale-tmp <path> age=<h>h` | Every direct child of `--tmp` (default `${TMPDIR:-/tmp}`) whose name matches `tmp.*` (the `mktemp` default), whose mtime is older than the stale age, and that is owned by the current user. Files and directories both count. `<h>` is whole hours since the entry's own mtime. |
| unpreserved artifact | `UNPRESERVED-ARTIFACT <file> cited by <block>` | Only with a scratchpad configured (kit #1207; see below). A file in the scratchpad whose basename or full path is mentioned by an `.md` block of the target, with no byte-identical copy under `<TARGET>/sources/probes/`: evidence about to be lost. |
| unmanifested script | `UNMANIFESTED-SCRIPT <file>` | Only with a scratchpad configured. A scratchpad script (extension `sh ps1 py java js rb pl bat cmd groovy kts`) whose basename is not the first table cell of any valid row of a `<TARGET>/sources/probes/**/SCRIPTS-MANIFEST.md`. |

Three more classes are **report-only retention warnings** (kit #1277 slice 3, maintainer decision 2026-10-07), described
in their own section below: `WARN stale-worktree`, `WARN merged-branch` / `WARN merged-remote-branch` and
`WARN stale-backup`. A WARN is never a finding: it cannot change the exit code, and clean-check is not a hard gate.

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

## Retention warnings (report-only, slice 3)

These scans only **propose**: nothing is deleted, pruned or moved. Each prints typed `WARN <class> ...` lines, counted in
the summary as `warnings: N` but **never** added to the finding count, so a repository with only WARNs still exits 0
(or 3 when a scan was degraded) and a real finding still exits 1. The operator or the campaign decides what to do.

| Class | Line | Rule |
|---|---|---|
| stale worktree | `WARN stale-worktree <path> missing` / `... prunable (<git's reason>)` | Every registered worktree of `--target` except the main one (first in `git worktree list --porcelain`; bare entries skipped) whose path no longer exists, or that git marks `prunable` while the path still exists (for example a removed `.git` file). A locked worktree is reported too, suffixed ` (locked)`: git itself never marks a locked worktree prunable, so a missing locked path is detected by the path check. |
| merged local branch | `WARN merged-branch <name> merged into <base>` | A `refs/heads/*` branch that `git for-each-ref --merged=<base>` lists. |
| merged remote-tracking ref | `WARN merged-remote-branch <remote/name> merged into <base>` | A `refs/remotes/*` ref listed by the same call. `<remote>/HEAD` aliases are skipped. |
| stale rollback backup | `WARN stale-backup <path> age=<d>d retention=<D>d` | An entry whose name contains `rollback` or `backup` (case-insensitive), 1 or 2 levels below an `_evidence` directory, whose own mtime is older than the retention age. `<d>` is whole days since that mtime. |

**Base for the branch scan.** `--base REF` (any commit-ish; unresolvable is exit 2), else `origin/HEAD` when it resolves,
else local `main`, else local `master`. When none exists the typed line `ABSENT-BASE ...` is printed, the scan is skipped
and the summary reads `branches: no base`; that is information, not a finding. Never reported: the base's own branch and
its local/remote twins (for example `main` when the base is `origin/main`), and any branch checked out in a worktree
(the main worktree included, so the branch `HEAD` is on). Known noise: a branch freshly created at the base tip is
"merged" by git's definition and is reported.

**Evidence backups.** `--evidence DIR` scans exactly that directory (a missing one prints `ABSENT-EVIDENCE <path>` and
the summary reads `evidence: absent`); without it every directory named `_evidence` up to 4 levels below `--target`
(`.git` excluded) is scanned, and none found reads `evidence: none found`. `--backup-days N` sets the retention age
(default **14** days, same decimal-integer rules as `--stale-hours`; `0` makes every matching backup stale). The keep-list
does not apply to these warnings.

**Degraded, never a silent zero.** A retention scan that cannot run prints a typed line and marks the run degraded:
`DEGRADED-WORKTREE-SCAN git worktree list failed: <git's reason>`, `DEGRADED-BRANCH-SCAN git for-each-ref failed: <reason>`,
`DEGRADED-EVIDENCE-SCAN find ... failed ...` (an unreadable `_evidence` subdirectory or a failing walk;
the walk's `find: '<path>': <reason>` stderr line stays visible). The summary then carries `degraded: <reasons>`; a run with no findings exits 3 and
reads `CLEAN-CHECK: degraded (...)`, a run with findings still exits 1. Absent (`ABSENT-BASE`, `ABSENT-EVIDENCE`),
empty (`evidence: none found`, `N dir(s) scanned, 0 older than ...`) and degraded are three distinct outputs.

## The session scratchpad

The scratchpad is the one declared place a session may write. It is named by `--scratchpad DIR`,
which wins over the `CLEAN_CHECK_SCRATCHPAD` environment variable (used when set and non-empty).

- **Exempt from the base classes.** An entry at or below the scratchpad is never reported as
  `untracked` or `stale-tmp`.
- **Scanned for lost evidence (kit #1207).** Every regular file in the scratchpad is checked
  against the target's blocks and manifests, producing the two finding classes below.
- **Live directory.** The scratchpad is read while the session keeps writing and deleting in it.
  A file that vanishes mid-walk is benign (the in-process walk ignores a missing entry); any other
  read error is still exit 2.

### `UNPRESERVED-ARTIFACT <file> cited by <block>`

A scratchpad file counts as cited when its basename or full path appears in an `.md` block of the
target (tracked or untracked, via `git ls-files -co`) as a whole path component: never a bare
substring, so `run.sh` is not matched by `prerun.sh`. `SCRIPTS-MANIFEST.md` files are excluded as
blocks (a manifest row names a script on purpose: it is the preservation record). The finding is
suppressed when a byte-identical copy (sha256) already sits anywhere under
`<TARGET>/sources/probes/`; such skips are counted in `preserved-copies:`. The remedy is to
preserve the file under `sources/probes/b<N>/` first. The sha256 is computed in process and streamed, so
files of any size are hashed in constant memory and no hash tool can be missing: `DEGRADED-NO-SHA256` and the
exit 3 it carried are retired (the script skipped the check without `sha256sum`/`shasum`). A file that cannot
be read has no copy and stays a finding. A symlinked `sources/probes` is not followed (it holds no files and
no manifests), so nothing outside the target can preserve or exempt a scratchpad file.

### `UNMANIFESTED-SCRIPT <file>`

The basename must equal, exactly, the last path component of the first table cell of some **valid** row
of any `SCRIPTS-MANIFEST.md` under `<TARGET>/sources/probes/`. A row is valid only when its second cell
is a 64-hex sha256: the header row, the separator row and rows with a placeholder digest list nothing.
Rows are read by the Go port of the shared parser (`core/kit.ScriptsManifestRows`, the port of
`lib/scripts-manifest.sh`), the same parser `verify-block.sh` uses for its `MANIFEST!` check; see
`verify-block.sh` for the row format. There is no bash helper to load any more, so "cannot find helper" (exit 2)
no longer exists; a manifest that cannot be read or parsed is still exit 2 (`cannot parse manifest <path>`,
fail closed, never "no rows").

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
(untracked in git order, stale-tmp sorted bytewise, then the scratchpad lines: `ABSENT-SCRATCHPAD`
when it applies, `UNPRESERVED-ARTIFACT` / `UNMANIFESTED-SCRIPT` per file in
sorted file order), then the retention section (worktree warnings or `DEGRADED-WORKTREE-SCAN`; `ABSENT-BASE` /
branch warnings or `DEGRADED-BRANCH-SCAN`; `ABSENT-EVIDENCE` / backup warnings in sorted order or
`DEGRADED-EVIDENCE-SCAN`), then one summary line. So a clean run with a keep-list, a resolvable base and no retention
warnings prints exactly one line, the summary; a clean run without a keep-list prints `ABSENT-KEEPLIST` and
the summary, and one without a resolvable base also prints `ABSENT-BASE` just before it. Two typed `INFO` lines can
precede the summary and never change the exit code: `INFO evidence-discovery skipped unreadable directory ...` (the
`_evidence` discovery `find` could not read a directory that is not under an `_evidence` dir; the message names it, and
`_evidence` dirs below it, if any, were not scanned; the summary's `evidence:` field then carries `, N unreadable dir(s) skipped`, so it never reads as a bare `none found`. The match is the C-locale `find: '<path>': Permission denied` shape anchored at both ends, classified on the path below the target with `_evidence` as a whole path component; anything else, or any such error under an `_evidence` dir, degrades) and `INFO merged-branch scan of local branches skipped ...` (the
worktree scan degraded, so which branches are checked out is unknown and local merged-branch WARNs are suppressed rather
than risk false ones; remote-tracking WARNs still run). A matching backup directory is reported once; backup-named
entries inside it are not listed separately. `git worktree list --porcelain -z` is used when git supports it (2.36+),
so a newline inside a worktree path is reported whole; older git falls back to the line form, where such a path is truncated.

```
CLEAN-CHECK: clean (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>, scratchpad: <state>, worktrees: <W>, branches: <B>, evidence: <E>, warnings: <N>)
CLEAN-CHECK: <N> finding(s) (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>, scratchpad: <state>, worktrees: <W>, branches: <B>, evidence: <E>, warnings: <N>)
```

`<state>` is one of the three scratchpad summary forms above. `<W>` is `<n> registered, <m> stale` or `degraded`;
`<B>` is `base <ref>, <l> local, <r> remote`, `no base` or `degraded`; `<E>` is `<n> dir(s) scanned, <m> older than <D>d`
(with `, <k> unreadable` when a directory could not be read), `none found`, `absent` or `degraded`; the trailing
`warnings: N` counts the retention WARN lines; a `degraded: <reasons>` suffix follows when a scan could not run.


| Exit | Meaning |
|---|---|
| 0 | clean (also `-h` / `--help`); retention WARNs alone still exit 0 |
| 1 | at least one finding |
| 2 | usage error (including a non-numeric `--backup-days`, an unresolvable `--base`, or an explicit empty value for `--target`, `--tmp`, `--scratchpad`, `--base` or `--evidence`: `--X needs a non-empty value`), `--target` absent or not inside a git work tree, `--tmp` absent, or a scan failed (including the scratchpad walk, the block listing, an unreadable block, the `sources/probes` manifest scan, a manifest that cannot be parsed, and a git listing cut at its 64 MiB output cap; a failing retention scan is exit 3 DEGRADED, not 2) |
| 3 | `DEGRADED`: either `git` is not on `PATH` (the only runtime dependency; the run stops there with no summary line and the typed `DEGRADED` line goes to stderr), or a retention scan could not run (the run completes: typed `DEGRADED-WORKTREE-SCAN` / `DEGRADED-BRANCH-SCAN` / `DEGRADED-EVIDENCE-SCAN` line, summary `CLEAN-CHECK: degraded (...)`; exit 3 only when there are no findings, otherwise 1). `DEGRADED-NO-SHA256` is retired. |

A scan that errors partway is exit 2, never a quiet "clean": a failed, timed-out or output-capped `git ls-files`,
or a `tmp.*` directory that cannot be listed, cannot read as an empty list. git's own stderr is shown, and a
`git rev-parse` failure reports git's reason (for example dubious ownership) instead of "not a work tree"; stderr
noise from a `git rev-parse` that succeeds is ignored (only its stdout is compared).

The instrument is `rsdd hygiene clean-check` (engine `internal/core/cleancheck`, entry `cleancheck.Check`);
`clean-check.sh` is a shim over it. Its only runtime dependency is `git`: the walks, sorting, clock, uid and hashing
are in process, and every relative path is resolved against the caller's working directory. Declared divergences
from the retired script are listed in `tool-registry.d/clean-check.md`.

## Terminal-trigger wiring (slice 2)

`research-sdd-status.sh <target> --next` runs this script (`--target <target>`, default `--tmp`) when its verdict is an
exhausted `STOP | read-only-investigable exhausted (0)`, and reports on STDERR only: `INFO: clean-check: clean at
terminal STOP` (exit 0), `WARN: clean-check: findings at terminal STOP` plus one `WARN: clean-check: <line>` per output
line (exit 1), or `WARN: clean-check: unverifiable (exit N: ...)` (exit 2/3, e.g. a corpus that is not a git work tree) /
`unverifiable (clean-check.sh not found ...)`. Report-only: the status stdout, verdict, `--emit-token` and exit code
are unchanged. `RSDD_STATUS_NO_CLEAN_CHECK=1` skips it; `RSDD_STATUS_CLEAN_CHECK_TIMEOUT` (default 20 s) bounds it (`unverifiable (timed out after Ns)`). Suite: `tests/research-sdd-status-clean-warn.test.sh`.

## Test hook

`CLEAN_CHECK_UID` overrides the uid used for the ownership filter (default `id -u`); the suite
uses it to prove the filter bites without needing a second user.

## Known limits

- The unreadable-directory skip is decided on a permission error from the in-process walk, which prints it
  in GNU find's `find: '<path>': Permission denied` shape on every platform.
- An entry that vanishes between listing and stat is benign everywhere (the walks ignore it), so the
  readdir race needs no flag and no BSD fallback.
- Stale age is the entry's own mtime. A directory's mtime moves when a direct child is added or
  removed, so a long-lived directory that is still being written can read as young.
- Only direct children of `--tmp` are examined.
- The retention scans are report-only by decision; there is no hard gate and no `--fail-on-warn`. Terminal wiring
  (`research-sdd-status.sh --next`) shows WARN lines only when the exit code is 1, because it relays the output of a
  run that exited 1; on exit 0 it prints just `INFO: clean-check: clean at terminal STOP`.
- `_evidence` backups are recognised by name (`*rollback*`, `*backup*`) and mtime only; an old backup that was edited
  recently reads as young, and a backup under a different name is invisible. Backups deeper than 2 levels below an
  `_evidence` directory are not examined.
- Branch merge status is git's ancestry test: a squash-merged branch is not an ancestor of the base, so it is not
  reported.
- Worktree paths containing a newline are handled only when git supports `worktree list -z` (2.36+); on older git the path is truncated at the newline.
