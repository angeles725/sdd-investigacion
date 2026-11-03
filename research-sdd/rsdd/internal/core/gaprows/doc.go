// Package gaprows reads the backlog-row side of the child-gap drift check: the `| <priority> | B<n>-G<m> <text> | ... |
// <status> |` rows of a RESEARCH-STATE file, the `- **B<n>-G<m>** <text>` bullets of a block file that define them,
// and the content-word overlap between the two. It is the Go port of toolbelt/lib/gap-rows.sh (gap_rows_parse,
// gap_bullet_text, gap_overlap; kit issues #1291, #1294, #2645) and is shared by the drift check
// (internal/verify/gapdrift), which `rsdd verify state` runs in process. Only what that check uses is exported (L68).
//
// Exported API:
//
//	Parse(src string) Table                    the typed records of a state file
//	Table.Records, Table.Empty                 the records by Kind; Empty is true for a zero-byte file
//	ParseBullets(src string) *Bullets          one pass over a block file
//	(*Bullets).Text(id string) (string, bool)  the defining bullet of an id, with its continuation lines
//	Overlap(row, bullet string) (shared, total int)
//
// Typed states (kit CLAUDE.md section 7), never collapsed into a bare zero:
//   - Table.Empty: the input has no bytes (empty-input).
//   - A Table with no records and Empty false: the input has text but no gap-id row (no-match).
//   - ParseBullets/Text: found=false is "this block file defines no such bullet" (no-match); the caller owns
//     absent-input (an unreadable block file is the caller's I/O error, not a missing bullet).
//   - Overlap total == 0: the row carries no comparable content word. That is "not checked", never "no drift".
//
// Reading rules, all byte-oriented (the bash original runs under LC_ALL=C): the row splitter is internal/core/gfm
// (ShapeLeadingPipe, trailing CR stripped, `\|` is a literal pipe); words are ASCII; nothing is read from disk here.
//
// Differences from lib/gap-rows.sh, each pinned by a test and listed in tool-registry.d/check-gap-drift.md:
//   - A literal 0x01 byte in a cell stays 0x01 (the awk used it as its pipe placeholder and turned it into `|`).
//   - The status test is an ASCII case fold (`PENDING`, `Pending ...`), as awk tolower was under LC_ALL=C.
package gaprows
