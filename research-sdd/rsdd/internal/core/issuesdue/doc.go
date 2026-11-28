// Package issuesdue is the read-only due computation behind `rsdd retro reconcile` and the ISSUES-DUE gate of
// `rsdd status show --next`: which open deltas of a §18 retro have no tracking issue, given the issue bodies of an
// --issues-cache. It was extracted from internal/retro/reconcile (kit issue #2644) so that status show answers in
// process instead of running `rsdd retro reconcile` once per probed retro; reconcile itself reads the retro, the
// cache and the signature prefixes through the same code. Only what those two callers use is exported (L68).
//
// Exported API:
//
//	Read(path, target string, sink Sink) (*Retro, bool)   the retro half of one audit: marker, row ids, open ids
//	(*Retro).Prefixes() []string                          the signature prefixes an issue of the retro can carry
//	(*Retro).Untracked(issueIDs []string) []string        the open rows no issue in issueIDs tracks, in row order
//	IssueRowIDs(bodies string, prefixes []string) []string the row ids the issue bodies claim for the prefixes
//	LeadingID(s string) string                            the run of [A-Za-z0-9_-] at the start of s
//	Normalize(text string) string                         the `$(cat file)` form of a cache file
//	ListLimit(get) (text string, n int, bad string)       RECONCILE_ISSUES_LIST_LIMIT
//	KitRoot(cwd, env, toolbelt, errf) (string, bool)      the legacy KIT_ROOT of the command
//	ResolveTarget(kitRoot, cwd, retro, env, sink)         the absolute retro path and its registered target name
//	Probe(Query) Result                                   `rsdd retro reconcile --issues-cache F <retro>`, in process
//
// Typed states (kit CLAUDE.md section 7), never collapsed into a bare zero. An empty Result.Untracked with no Failure and
// no OutOfScope is the one clean verdict: the retro was read and classified, and every open row has an issue (or the
// retro has no open row). Result.Failure is "could not look" (a degraded or absent-input stop: rc 1 of the command),
// and Result.OutOfScope is "looked, but the review-status marker sits outside the leading block, so no row was
// classified". Neither is ever reported as zero untracked rows.
package issuesdue
