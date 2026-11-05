// Package migratebacklogs is `rsdd corpus migrate-backlogs <corpus-dir>`: the port of toolbelt/migrate-backlogs.sh
// (kit issue #2684, epic #2270), the PROPOSE-ONLY §8b gap-backlog migration of kit issue #1543.
//
// A corpus written before the §8b grammar closed carries heading variants, `open`/`queued` statuses,
// `critical`/`med` tiers, qualified priorities and a FOCUSES.md `closed` token. Each makes verify-state FAIL and,
// corpus-wide, bricks `research-sdd-status.sh --next` with STALE. The command prints the mechanical part of that
// migration as a unified diff per file and a typed MANUAL line for everything else. It NEVER writes to the target
// (propose-never-apply, CLAUDE.md section 8): every transform is computed in memory and the corpus is only read.
//
// Mechanical transforms (METHODOLOGY section 8b, "Migration"):
//   - heading: a near-miss backlog heading over a priority-led table becomes `## Gap-backlog`;
//   - skeleton: a state file with no backlog at all (and not a `document` focus) gets an empty canonical section;
//   - priority: `critical` to `high`, `med` to `medium`, bold and case folded, `low (deferred)` to `deferred`, a
//     qualifier moved to the end of the Status cell;
//   - status: a leading `open`/`queued` becomes `pending`;
//   - focuses: FOCUSES.md `closed` becomes `stopped` and `reabierto` becomes `reopened`.
//
// Typed lines on stdout, in the order a file is reported: `PROPOSE <label> <file>` and the diff;
// `MANUAL <label> <reason> rows=<N> first-line=<L>` once per reason (unknown-priority, emdash-open-row,
// bare-closure-word, unknown-status-token, malformed-row, unknown-focus-status, multiple-backlog-sections,
// empty-backlog-skeleton, non-priority-backlog-table, unrecognised-backlog-heading, unsupported-table-width
// cols=N); `ok <label>: nothing to migrate`; `empty-input: <label> (<file> is empty)`; `absent-input: ...` for a
// corpus with no state file; and always the closing `migrate-backlogs: N file(s) inspected · M with a mechanical
// proposal · K MANUAL line(s)`, so a zero can be told from a run that never looked (CLAUDE.md section 7).
//
// Exit: 0 inspected (proposals are findings, not failures) - 1 operational failure (an unlistable corpus or
// subdirectory, an unreadable file), always with a typed `degraded: migrate-backlogs: ...` line on stderr and no
// closing line - 2 bad arguments, or a target that is not a directory.
//
// Tables are read through core/gfm with the Padded view: a cell keeps its padding and its `\|` escape, so an
// untouched row is rebuilt byte for byte and a rewritten cell keeps the padding around its new text.
//
// Subprocesses: none. The script started awk, diff, find, sort, mktemp, cut, wc, basename and dirname; the
// transforms, the file search and the unified diff are computed in process, which also removes the five degraded
// reasons of a missing tool or helper. Options.FS is the seam through which the tests reach the degraded paths.
//
// The divergences from the frozen script (testdata/legacy) are pinned by divergence_test.go and listed in
// toolbelt/tool-registry.d/migrate-backlogs.md.
package migratebacklogs
