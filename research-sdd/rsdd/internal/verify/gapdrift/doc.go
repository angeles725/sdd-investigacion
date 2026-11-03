// Package gapdrift is `rsdd verify gap-drift <target-dir> [--state <file>] [--threshold <pct>] [--all]`: the check
// that flags RESEARCH-STATE backlog rows whose text drifted from the child-gap bullet that defines them. It is the Go
// port of toolbelt/check-gap-drift.sh (kit issues #1291, #1294, #2645) and the in-process checker of `rsdd verify
// state`; the row, bullet and overlap rules are internal/core/gaprows.
//
// A backlog row `| <priority> | B<n>-G<m> <text> | ... | <status> |` is a promoted COPY of the bullet
// `- **B<n>-G<m>** <text>` in block <n>'s child-gaps list. A row that shares fewer than THRESHOLD percent (default 20)
// of its content words with its bullet is suspected drift.
//
// Typed API for in-process callers (status show, state-update, verify state):
//
//	OpenCorpus(cwd, target string) (*Corpus, error)     list the block files once; *Error on a listing failure
//	(*Corpus).Check(state, label string, o Options) (Result, error)
//	                                                    compare every row of one state file's text; *Error when a
//	                                                    block file cannot be read
//	Result.Outcome                                      OutcomeChecked, OutcomeEmptyInput, OutcomeNoRows,
//	                                                    OutcomeNoPending or OutcomeDegraded: absent, empty,
//	                                                    no-match and degraded stay distinct (kit CLAUDE.md section 7)
//	Result.Findings, Result.Counts, Result.ExitCode()
//	Result.Render(w)                                    the script's report, byte for byte
//
// Exit codes of the command: 0 no drift suspected, 1 drift or unparsed rows (findings only), 2 every operational
// failure (usage, unreadable state, a block file that cannot be listed or read).
//
// Differences from check-gap-drift.sh (each pinned by a test; the list is tool-registry.d/check-gap-drift.md):
//   - --threshold is read as decimal (the script's arithmetic read 010 as octal 8 and aborted on 08).
//   - The nested-worktree prune (<target>/.claude/worktrees) is literal: a trailing slash or a glob character in the
//     target no longer disables or widens it.
//   - Block files of one block number are tried in bytewise path order (the script used readdir order).
//   - An UNPARSED line is printed whole (its first 90 bytes); the script cut it at its first tab.
//   - The row text of a DRIFT? line is cut at 90 characters (UTF-8; invalid bytes count one each), where the script's
//     ${text:0:90} followed the caller's locale.
package gapdrift
