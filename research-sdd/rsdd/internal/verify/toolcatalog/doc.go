// Package toolcatalog is `rsdd verify tool-catalog [<toolbelt-dir>]` and its SessionStart hook `rsdd verify
// tool-catalog-hook [<toolbelt-dir>] [--full]`: the drift guard between the tools logged in INSTALLED-TOOLS.md and
// the capability catalog tool-registry.md (kit issue #2749, the Go port of the two toolbelt scripts of that name).
//
// For every distinct tool name logged in INSTALLED-TOOLS.md (the rows of the auto-log table, then the hand-written
// "## <tool> (...)" headings) the check WARNs when tool-registry.md has no case-insensitive whole-word mention of
// it. It never edits either file (propose-never-apply); it exits 1 only on an operational failure.
//
//	absent-input   an input is not a file                             exit 1, ERROR on stderr
//	empty-input    the log names no tool                              exit 0, its own sentence
//	no-match       every logged tool is cataloged                     exit 0, the consistent line
//
// The hook prints a declared-clean sentinel, nothing on an empty log, a compact drift report (the per-tool WARN
// lines collapsed into one line naming every tool; --full keeps them) and, when the check could not run or printed
// no Summary line, a context capped by hookenv.FailureContext. It always exits 0.
//
// Locale: like the scripts, character classes and case follow LC_ALL, else LC_CTYPE, else LANG. In a UTF-8 locale
// a character is a rune and the classes are Unicode's; elsewhere a byte, and only ASCII has a case or a class.
//
// Differences from the scripts (each pinned by a test; the list is tool-registry.d/verify-tool-catalog.md):
//   - An input that exists but cannot be read is an operational failure (exit 1, "unreadable-input"). The script
//     swallowed the read error and reported an empty log, or every tool as uncataloged.
//   - The envelope is always JSON; the script printed plain text when jq was missing.
//   - The check takes at most one non-empty argument; the script ignored its arguments.
//   - The hook reads --full anywhere and one directory; any other call is a capped usage context. The script read
//     only $1 == --full and dropped the rest unseen.
//   - The "WARN-line extraction failed" notice is gone with grep: selecting lines in Go cannot fail.
package toolcatalog
