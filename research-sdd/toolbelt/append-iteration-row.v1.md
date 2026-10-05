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
| Table | The first table under the heading, before the next heading of any level: header row, `\|---\|` separator row, then contiguous rows. A row is a line whose text, with inline `<!-- -->` comments removed, starts with `\|` (so `| a | b | <!-- note -->` is a row). A table inside a comment is skipped. |
| Insertion | After the table's last row (after the separator when the table is empty). Every other byte is preserved. A blank line is inserted between the new row and the next line when that line is not already blank; the file always ends in a newline. |
| Row | One line without `<!--` or `-->` (INVALID-ROW: an unterminated opener would comment out the rest of the file). Outer pipes are optional (`2 \| d \| g` is normalised to `\| 2 \| d \| g \|`). `\|` inside a cell is an escaped pipe, not a separator. Content is written verbatim. |
| Cell count | The row must have exactly the header's cell count, else CELL-COUNT-MISMATCH. |
| `--apply` | Works from one snapshot of the target taken at start. Writes a temp file in the target's directory (mode copied with `cp -p`), then, after re-checking with `cmp` that the target still equals the snapshot (else CONCURRENT-MODIFICATION), `mv -f` over the target. No lock is taken, so a write landing between the `cmp` and the `mv` is not detected. A failure leaves the original in place. A symlink target is refused (`mv` would replace the link). |
| Output | Dry run: unified diff (`a/<name>` / `b/<name>`) on stdout, one notice on stderr. `--apply`: one confirmation on stderr. |

## Exit codes and typed errors

Every failure prints exactly ONE line, `append-iteration-row: ERROR: <TYPE> ...`, on stderr, usage failures included (the DEGRADED probe uses `append-iteration-row: DEGRADED: ...`) and leaves the file untouched. Usage text is printed only by `--help` (stdout, exit 0), never on a failure.

| Exit | Type | Meaning |
|---|---|---|
| 0 | | Diff printed (dry run) or file written (`--apply`). |
| 2 | `USAGE` / `INVALID-ROW` / `ABSENT-FILE` / `NOT-REGULAR-FILE` | Bad arguments, blank or multi-line row, missing path, directory, unreadable file or symlink. |
| 3 | `DEGRADED` | A required tool (`awk diff mktemp mv cp cat dirname cmp rm`) is missing; nothing was measured. |
| 4 | `NO-HEADING` | No `## Iteration history` heading outside an HTML comment. |
| 5 | `NO-TABLE` | Heading found, no table row before the next heading. |
| 6 | `MALFORMED-TABLE` | Header row not followed by a `\|---\|` separator row, or the last table row opens an HTML comment that closes on a later line (a row appended after it would be hidden). |
| 7 | `CELL-COUNT-MISMATCH` | Row cell count differs from the header's. |
| 8 | `AMBIGUOUS-HEADING` | More than one heading outside comments; the tool will not guess. |
| 9 | `WRITE-FAILED` | Staging, `diff`, `cmp` (rc >= 2, not "differs") or `mv` failed (`--apply`), or awk crashed. |
| 10 | `CONCURRENT-MODIFICATION` | `--apply` only: the target is no longer byte-identical to the snapshot the new content was computed from; nothing is written, re-run. |

Absent file (2), missing heading (4), missing table (5) and malformed table (6) are distinct states, never
one silent "nothing appended".

## Not owned

Counters (`known_gaps`, `blocked_open`, `last_iteration_ts`, ...) stay with `state-update.sh` and
`research-sdd-status.sh --sync-state`; this tool owns only the history row. It does not validate the cell
contents (block ids, dates, the New-gaps grammar of METHODOLOGY §8b): only the cell count.

## Tests

`tests/append-iteration-row.test.sh` (`--prove-teeth` adds the mutation controls). Run it against a COPY of a
real corpus file, never the live one, when checking a new table shape.
