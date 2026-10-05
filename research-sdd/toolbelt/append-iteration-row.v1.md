# Iteration-row appender `append-iteration-row.v1`

`append-iteration-row.sh [--apply] <RESEARCH-STATE.md> "<row>"` appends ONE row to the
`## Iteration history` table of a `RESEARCH-STATE*.md` without gluing it onto the next heading
(kit issue #1606: three hand-appended rows in one run lost their separation from the following
heading and drove `blocked_open` from 64 to 0).

Propose-never-apply, like `state-update.sh`: the default is a **dry run** that prints a unified diff and
never writes. `--apply` is the explicit opt-in that writes the file. The tool never commits, pushes or
touches any other file (the auto-commit part of #1198 is deliberately out of scope).

## Contract

| Item | Value |
|---|---|
| Heading | The exact line `## Iteration history` (trailing whitespace allowed), as in `templates/RESEARCH-STATE.template.md`. A heading with extra text is not matched. |
| Comment blindness | Text inside `<!-- ... -->` (multi-line included) is removed before matching, so a heading or table row inside a comment never matches (kit #1173: the template carries heading text inside comments). |
| Fenced code | Lines of a fenced code block (``` or ~~~, up to 3 spaces of indent, closed by the same character with a run at least as long) are invisible: no heading, table row or comment opener inside one counts (kit #1793). A fence that never closes and hides the heading or the table under it is `UNCLOSED-FENCE`, not `NO-HEADING` / `NO-TABLE`; an unclosed fence after the table is not an error. `UNCLOSED-FENCE` is raised only when the open fence could have hidden what is missing: the heading line itself sits inside it, or (for the table) it opened after the heading and before the next heading; any other unclosed fence leaves `NO-HEADING` / `NO-TABLE` as is. |
| Line endings | LF only. Any carriage return in the file is refused with `CRLF-LINE-ENDINGS` (exit 11) before anything else is examined, so a CRLF file is never misreported as `NO-HEADING`. Chosen by survey: on 2026-10-05, 201 `RESEARCH-STATE*.md` files under `~/investigacion` (worktree copies excluded) held 0 CR bytes, so no CRLF write path exists to maintain (kit #1793). |
| Table | The first table under the heading, before the next heading of any level: header row, `\|---\|` separator row, then contiguous rows. A row is a line whose text, with inline `<!-- -->` comments removed, starts with `\|` (so `| a | b | <!-- note -->` is a row). A table inside a comment is skipped. |
| Insertion | After the table's last row (after the separator when the table is empty). Every other byte is preserved. A blank line is inserted between the new row and the next line when that line is not already blank; the file always ends in a newline. |
| Row | One line without `<!--` or `-->` (INVALID-ROW: an unterminated opener would comment out the rest of the file). Outer pipes are optional (`2 \| d \| g` is normalised to `\| 2 \| d \| g \|`). `\|` inside a cell is an escaped pipe, not a separator; a closing pipe preceded by an ODD number of backslashes is itself escaped (a closing pipe is added), by an EVEN number (`\\|`) it is a real pipe, the same rule the cell counter uses. Content is written verbatim. |
| Cell count | The row must have exactly the header's cell count, else CELL-COUNT-MISMATCH. |
| `--apply` | Works from one snapshot of the target taken at start. Writes a temp file in the target's directory (metadata copied with `cp --preserve=all`, falling back to `cp -p`), then, after re-checking with `cmp` that the target still equals the snapshot (else CONCURRENT-MODIFICATION), `mv -f` over the target. No lock is taken, so a write landing between the `cmp` and the `mv` is not detected. A failure leaves the original in place. A symlink target is refused (`mv` would replace the link). `mv` replaces the inode, so a target with more than one hard link is refused with `HARD-LINKED` (exit 13) rather than silently splitting the links (dry runs are unaffected). The link count is checked before staging and again right after the `cmp` guard, immediately before the `mv`; a link created after that last check is not detected, the same unlocked window the `cmp` guard already documents. The staged copy is made with GNU `cp --preserve=all` (mode, owner, timestamps, xattrs, ACLs, SELinux context) and falls back to `cp -p` where that flag is absent, so metadata survives on a best-effort basis, but the inode itself is new: anything keyed on the inode (open handles, watches on the file) does not follow. Copy-in-place was rejected because it trades these limits for a non-atomic truncate-then-write that can leave a partial state file. |
| Output | Dry run: unified diff (`a/<name>` / `b/<name>`) on stdout, one notice on stderr. `--apply`: one confirmation on stderr. |

## Exit codes and typed errors

Every failure prints exactly ONE line, `append-iteration-row: ERROR: <TYPE> ...`, on stderr, usage failures included (the DEGRADED probe uses `append-iteration-row: DEGRADED: ...`) and leaves the file untouched. Usage text is printed only by `--help` (stdout, exit 0), never on a failure.

| Exit | Type | Meaning |
|---|---|---|
| 0 | | Diff printed (dry run) or file written (`--apply`). |
| 2 | `USAGE` / `INVALID-ROW` / `ABSENT-FILE` / `NOT-REGULAR-FILE` | Bad arguments, blank or multi-line row, missing path, directory, unreadable file or symlink. |
| 3 | `DEGRADED` | A required tool (`awk diff mktemp mv cp cat dirname cmp rm ls`) is missing; nothing was measured. |
| 4 | `NO-HEADING` | No `## Iteration history` heading outside an HTML comment. |
| 5 | `NO-TABLE` | Heading found, no table row before the next heading. |
| 6 | `MALFORMED-TABLE` | Header row not followed by a `\|---\|` separator row, or the last table row opens an HTML comment that closes on a later line (a row appended after it would be hidden). |
| 7 | `CELL-COUNT-MISMATCH` | Row cell count differs from the header's. |
| 8 | `AMBIGUOUS-HEADING` | More than one heading outside comments; the tool will not guess. |
| 9 | `WRITE-FAILED` | Staging, `diff`, `cmp` (rc >= 2, not "differs") or `mv` failed (`--apply`), or awk crashed. |
| 10 | `CONCURRENT-MODIFICATION` | `--apply` only: the target is no longer byte-identical to the snapshot the new content was computed from; nothing is written, re-run. |
| 11 | `CRLF-LINE-ENDINGS` | The file contains a carriage return (CRLF or mixed endings); convert to LF and re-run. |
| 12 | `UNCLOSED-FENCE` | No heading, or no table under it, is visible because a code fence opens and never closes. |
| 13 | `HARD-LINKED` | `--apply` only: the target has more than one hard link; nothing is written. |

Absent file (2), missing heading (4), missing table (5) and malformed table (6) are distinct states, never
one silent "nothing appended".

## Not owned

Counters (`known_gaps`, `blocked_open`, `last_iteration_ts`, ...) stay with `state-update.sh` and
`research-sdd-status.sh --sync-state`; this tool owns only the history row. It does not validate the cell
contents (block ids, dates, the New-gaps grammar of METHODOLOGY §8b): only the cell count.

## Tests

`tests/append-iteration-row.test.sh` (`--prove-teeth` adds the mutation controls). Run it against a COPY of a
real corpus file, never the live one, when checking a new table shape.
