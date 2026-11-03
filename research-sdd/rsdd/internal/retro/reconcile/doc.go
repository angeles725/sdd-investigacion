// Package reconcile is the Go port of toolbelt/reconcile-issues.sh (kit issue #2563): it audits GitHub issue
// coverage for the OPEN deltas of a §18 retro.
//
// Slice 1 covers ONE retro audited against a pre-fetched open-issue cache (the open classes tracked, untracked
// and orphaned). Slice 2 adds the pre-fetched closed-issue cache (Options.ClosedCache): the shipped, borderline
// and regressed classes, the closure-evidence grammar, repository reachability (RECONCILE_ISSUES_MAIN_REF and
// RECONCILE_ISSUES_GIT_DIR, read through Options.Env) and the shallow-clone note. --all and live gh follow in
// the next slice; until then a nil Options.IssuesCache is a typed operational error (ErrNotInSlice).
package reconcile
