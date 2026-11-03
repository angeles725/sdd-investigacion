// Package reconcile is the Go port of toolbelt/reconcile-issues.sh (kit issue #2563): it audits GitHub issue
// coverage for the OPEN deltas of a §18 retro.
//
// Slice 1 covers ONE retro audited against a pre-fetched open-issue cache (the open classes tracked, untracked
// and orphaned). The closed-issue classes (shipped, borderline, regressed), --all and live gh follow in later
// slices; until then a nil Options.IssuesCache is a typed operational error (ErrNotInSlice).
package reconcile
