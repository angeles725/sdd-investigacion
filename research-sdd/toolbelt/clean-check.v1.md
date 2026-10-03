# `clean-check.v1`

`clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N]` is a **read-only** instrument that
reports leftovers a run should not leave behind (kit issue #1277, the NO-GARBAGE rule). It lists;
it never deletes, moves, or edits anything (propose-never-apply): the operator or the campaign
decides what to do with each finding.

## What it scans

| Class | Finding line | Rule |
|---|---|---|
| untracked | `GARBAGE untracked <path>` | Every untracked, **non-ignored** file under `--target` (default `.`) that no keep-list glob matches. Listed by `git ls-files --others --exclude-standard`, so `.gitignore`d files are never findings and an untracked directory is expanded to its files. |
| stale temp | `GARBAGE stale-tmp <path> age=<h>h` | Every direct child of `--tmp` (default `${TMPDIR:-/tmp}`) whose name matches `tmp.*` (the `mktemp` default), whose mtime is older than the stale age, and that is owned by the current user. Files and directories both count. `<h>` is whole hours since the entry's own mtime. |

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

An entry at or below the directory named by `CLEAN_CHECK_SCRATCHPAD` (when set and non-empty)
is never reported, in either class. That is the one declared place a session may write.

## Output and exit codes

Output order: the `ABSENT-KEEPLIST` line (only when `keep.txt` is missing), then the finding lines
(untracked in git order, stale-tmp sorted), then one summary line. So a clean run with a keep-list
prints exactly one line, the summary; a clean run without a keep-list prints `ABSENT-KEEPLIST` and
the summary.

```
CLEAN-CHECK: clean (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>)
CLEAN-CHECK: <N> finding(s) (untracked in <target>, tmp.* in <tmp> older than <H>h, keep-list entries: <K>)
```

| Exit | Meaning |
|---|---|
| 0 | clean |
| 1 | at least one finding |
| 2 | usage error, `--target` absent or not inside a git work tree, `--tmp` absent, or a scan command failed |
| 3 | `DEGRADED`: a tool in the script's `REQUIRED_TOOLS` list (`git find date sort`) is not on `PATH`; nothing was measured (the typed `DEGRADED` line goes to stderr) |

A scan that errors partway is exit 2, never a quiet "clean": the untracked list is read with an
explicit end marker so a truncated `git` run cannot read as an empty one.

## Test hook

`CLEAN_CHECK_UID` overrides the uid used for the ownership filter (default `id -u`); the suite
uses it to prove the filter bites without needing a second user.

## Known limits

- A `tmp.*` entry that vanishes between readdir and stat would make `find` fail. Where `find`
  supports `-ignore_readdir_race` (GNU) the scan uses it and the race is benign; where it does not
  (BSD) the scan still exits 2 loudly on such a race, and a rerun is the remedy.
- Stale age is the entry's own mtime. A directory's mtime moves when a direct child is added or
  removed, so a long-lived directory that is still being written can read as young.
- Only direct children of `--tmp` are examined.
- Stale worktrees, merged branches and `_evidence` retention (also named in #1277) are not
  scanned by v1.
