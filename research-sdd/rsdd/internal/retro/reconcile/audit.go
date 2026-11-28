package reconcile

import (
	"context"
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/issuesdue"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// audit is audit_retro for the open classes: it reads the retro once, classifies every open delta against the
// issue bodies of the cache and reports the orphaned issues. Messages and their order are the legacy script's.
type audit struct {
	ctx    context.Context
	sess   *session
	closed *Cache // nil = no --closed-cache
	reg    regState
	rep    *Report
	path   string // absolute retro path
	base   string // its base name
	target string // registered target name (or the basename fallback)
	cache  *Cache // nil = the live per-retro gh query
	gh     *ghClient

	ret *issuesdue.Retro // the retro read for the due computation (core/issuesdue)
	doc *retrogrammar.Doc
}

func (a *audit) run() {
	r := a.rep
	ret, ok := issuesdue.Read(a.path, a.target, r.sink())
	if !ok {
		return
	}
	a.ret, a.doc = ret, ret.Doc
	var bodies string
	if a.cache == nil { // the live gh query (RECONCILE_ISSUES_CACHE_BRANCH is its counterpart)
		var ok bool
		if bodies, ok = a.gh.openBodies(r, a.base, ret.Prefixes()); !ok {
			return
		}
	} else {
		var err error
		if bodies, err = a.cache.read(); err != nil {
			r.degrade("degraded: --issues-cache file not readable: %s", a.cache.path)
			return
		}
	}
	issueIDs := issuesdue.IssueRowIDs(bodies, ret.Prefixes())
	if !a.classify(issueIDs) {
		return
	}
	a.orphans(issueIDs)
	if len(r.Tracked)+len(r.Untracked)+len(r.Orphaned)+len(r.Shipped)+len(r.Borderline) == 0 {
		r.note("no-match: no open deltas and no orphaned issues in %s", a.base)
	}
	r.done = true
}

// classify decides, for every open row, tracked, untracked or one of the closed-issue classes. false stops the
// audit (an unreadable --closed-cache, or the context ending).
func (a *audit) classify(issueIDs []string) bool {
	r := a.rep
	closedLoaded, closedBodies := false, ""
	noOpenIssue := a.ret.Untracked(issueIDs)
	for _, id := range a.ret.OpenIDs {
		if a.ctx.Err() != nil {
			return false
		}
		if !slices.Contains(noOpenIssue, id) {
			r.out("tracked: row %s — open issue found in %s", id, a.base)
			r.Tracked = append(r.Tracked, Delta{Row: id, Retro: a.base})
			continue
		}
		// No OPEN issue is not yet "no issue" (kit issue #1555): the row may have shipped through an issue since
		// closed as completed. Read once per retro, only when a row has no open issue. Without a closed cache the
		// check cannot run: say so instead of reading it as "no closed issue".
		if !closedLoaded {
			closedLoaded = true
			switch {
			case a.closed != nil:
				text, err := a.closed.read() // RECONCILE_ISSUES_CLOSED_CACHE_READ
				if err != nil {
					r.degrade("degraded: --closed-cache file not readable: %s", a.closed.path)
					return false
				}
				closedBodies = text
			case a.cache != nil:
				r.note("closed-lookup: skipped for %s — --issues-cache without --closed-cache; rows with no open issue are not checked against closed issues", a.base)
			default:
				text, ok := a.gh.closedBodies(r, a.base, a.ret.Prefixes())
				if !ok {
					return false
				}
				closedBodies = text
			}
		}
		if rec := a.closedEvidence(closedBodies, id); rec != "" { // RECONCILE-CLOSED-SHIPPED
			a.closedRow(id, rec)
			continue
		}
		r.out("untracked: row %s — no open issue found for this delta in %s", id, a.base)
		r.Untracked = append(r.Untracked, Delta{Row: id, Retro: a.base})
	}
	return true
}

// closedEvidence is the closed-issue records of a row under every signature prefix of the retro, "" when none.
func (a *audit) closedEvidence(bodies, id string) string {
	if bodies == "" {
		return ""
	}
	var ev string
	for _, p := range a.ret.Prefixes() {
		rec, ignored := closedRecords(bodies, p, id)
		if ignored > 0 {
			a.rep.note("note: closed-cache: %d line(s) before the first signature line belong to no record (ignored)", ignored)
		}
		if rec = strings.TrimRight(rec, "\n"); rec != "" {
			ev += rec + "\n"
		}
	}
	return ev
}

// closedRow reports a row whose issue was closed as completed: shipped when the closure evidence holds (kit issue
// #1709: a commit AND a test cited, and a cited commit that reaches the main ref), else borderline.
func (a *audit) closedRow(id, rec string) {
	r := a.rep
	v := a.sess.check(r, rec)
	if len(v.missing) > 0 {
		why := strings.Join(v.missing, "; ")
		r.out("borderline: row %s — its issue is closed as completed and cites this retro in %s, but the closure evidence is incomplete (%s); human review (not shipped, not untracked, nothing edited)", id, a.base, why)
		r.Borderline = append(r.Borderline, Delta{Row: id, Retro: a.base, Why: why})
		return
	}
	r.out("shipped: row %s — its issue is closed as completed and cites this retro in %s; propose marking the row shipped in the retro marker (not edited here) [evidence: commit %s reachable from %s (local ref, no fetch); test cited]", id, a.base, v.reach, a.sess.mainRef)
	r.Shipped = append(r.Shipped, Delta{Row: id, Retro: a.base, Why: v.reach})
	// RECONCILE_ISSUES_REGRESSED: a shipped row proposed again, open, in a later retro.
	if line := a.regressed(id, rec); line != "" { // RECONCILE-REGRESSED-CALL
		r.out("%s", line)
		r.Regressed = append(r.Regressed, Delta{Row: id, Retro: a.base, Why: strings.TrimPrefix(line, "regressed: ")})
	}
}

// orphans reports the issues whose row is no longer open, with the reason when the marker proves it (kit issue
// #1492): a row merely absent from the retro gets no claim.
func (a *audit) orphans(issueIDs []string) {
	r := a.rep
	for _, id := range issueIDs {
		if slices.Contains(a.ret.OpenIDs, id) {
			continue
		}
		why := ""
		state := retrogrammar.RowNotPartial
		if a.ret.Partial {
			state = retrogrammar.MarkerRowState(a.ret.Marker, id)
		}
		switch {
		case a.ret.Partial && slices.Contains(a.ret.Shipped, id):
			why = " — the retro marker lists it shipped; propose closing the issue (not closed here)"
		case state == retrogrammar.RowDismissed:
			why = " — the retro marker lists it dismissed; propose closing the issue (not closed here)"
		case state == retrogrammar.RowMalformed:
			why = " — marker DISMISSED list malformed; cannot tell"
		case slices.Contains(a.ret.AllIDs, id) && (a.ret.Status == "applied" || a.ret.Status == "dismissed"):
			why = " — the retro review-status is " + a.ret.Status + "; propose closing the issue (not closed here)"
		}
		r.out("orphaned: issue for row %s is no longer open in %s%s", id, a.base, why)
		r.Orphaned = append(r.Orphaned, Delta{Row: id, Retro: a.base, Why: strings.TrimPrefix(why, " — ")})
	}
}
