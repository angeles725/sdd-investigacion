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
| Table | The first table under the heading, before the next heading of any level: header row, `\|---\|` separator row, then contiguous `\|` rows. A table inside a comment is skipped. |
| Insertion | After the table's last row (after the separator when the table is empty). Every other byte is preserved. A blank line is inserted between the new row and the next line when that line is not already blank; the file always ends in a newline. |
| Row | One line. Outer pipes are optional (`2 \| d \| g` is normalised to `\| 2 \| d \| g \|`). `\|` inside a cell is an escaped pipe, not a separator. Content is written verbatim. |
| Cell count | The row must have exactly the header's cell count, else CELL-COUNT-MISMATCH. |
| `--apply` | Writes a temp file in the target's directory (mode copied with `cp -p`), then `mv -f` over the target. A failure leaves the original in place. A symlink target is refused (`mv` would replace the link). |
| Output | Dry run: unified diff (`a/<name>` / `b/<name>`) on stdout, one notice on stderr. `--apply`: one confirmation on stderr. |

## Exit codes and typed errors

Every failure prints `append-iteration-row: ERROR: <TYPE> ...` on stderr and leaves the file untouched.

| Exit | Type | Meaning |
|---|---|---|
| 0 | | Diff printed (dry run) or file written (`--apply`). |
| 2 | `USAGE` / `ABSENT-FILE` / `NOT-REGULAR-FILE` | Bad arguments, blank or multi-line row, missing path, directory, unreadable file or symlink. |
| 3 | `DEGRADED` | A required tool (`awk diff mktemp mv cp cat dirname`) is missing; nothing was measured. |
| 4 | `NO-HEADING` | No `## Iteration history` heading outside an HTML comment. |
| 5 | `NO-TABLE` | Heading found, no table row before the next heading. |
| 6 | `MALFORMED-TABLE` | Header row not followed by a `\|---\|` separator row. |
| 7 | `CELL-COUNT-MISMATCH` | Row cell count differs from the header's. |
| 8 | `AMBIGUOUS-HEADING` | More than one heading outside comments; the tool will not guess. |
| 9 | `WRITE-FAILED` | Staging, `diff` or `mv` failed (`--apply`), or awk crashed. |

Absent file (2), missing heading (4), missing table (5) and malformed table (6) are distinct states, never
one silent "nothing appended".

## Not owned

Counters (`known_gaps`, `blocked_open`, `last_iteration_ts`, ...) stay with `state-update.sh` and
`research-sdd-status.sh --sync-state`; this tool owns only the history row. It does not validate the cell
contents (block ids, dates, the New-gaps grammar of METHODOLOGY §8b): only the cell count.

## Tests

`tests/append-iteration-row.test.sh` (`--prove-teeth` adds the mutation controls). Run it against a COPY of a
real corpus file, never the live one, when checking a new table shape.
