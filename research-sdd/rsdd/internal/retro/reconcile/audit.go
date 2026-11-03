package reconcile

import (
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// audit is audit_retro for the open classes: it reads the retro once, classifies every open delta against the
// issue bodies of the cache and reports the orphaned issues. Messages and their order are the legacy script's.
type audit struct {
	rep    *Report
	path   string // absolute retro path
	base   string // its base name
	target string // registered target name (or the basename fallback)
	cache  *Cache

	marker   string
	status   string
	partial  bool
	shipped  []string
	allIDs   []string
	openIDs  []string
	doc      *retrogrammar.Doc
	foundSec bool
}

func (a *audit) run() {
	r := a.rep
	// `[ ! -r ]`: an existing but unreadable retro is not an empty one (every parse would see nothing).
	f, err := os.Open(a.path)
	if err == nil {
		_ = f.Close()
	}
	doc, rerr := retrogrammar.Read(a.path)
	if err != nil || rerr != nil {
		r.degrade("degraded: retro not readable: %s — cannot audit, no verdict", a.path)
		return
	}
	a.doc = doc
	a.marker = retrogrammar.MarkerScopeLine(doc)
	// A marker outside the leading-block scope is a corpus FINDING (kit issue #1099/#1125): nothing is
	// classified, and the run does not fail.
	if a.marker == "" && retrogrammar.MarkerOutOfScope(doc) {
		r.OutOfScopeMarker = "out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in " + a.base +
			" — refusing to classify (kit issue #1099); move the marker into the leading block"
		r.Notes = append(r.Notes, r.OutOfScopeMarker)
		return
	}
	a.status = retrogrammar.StatusFromMarkerLine(a.marker)
	if retrogrammar.MarkerIsPartial(a.marker) {
		a.partial = true
		if raw := retrogrammar.ShippedRaw(a.marker); raw != "" {
			ids, err := retrogrammar.ShippedIDs(raw)
			if err != nil {
				r.degrade("degraded: the review-status marker of %s lists a shipped: range too large to expand (%s)", a.base, err.Error())
				return
			}
			a.shipped = ids
		}
	}
	if !a.classifySection() {
		return
	}
	hasOpen := a.openRows()
	if !a.collectIDs() {
		return
	}
	if hasOpen {
		a.buildOpenIDs()
	}
	bodies, err := a.cache.read()
	if err != nil {
		r.degrade("degraded: %s", err.Error())
		return
	}
	issueIDs := issueRowIDs(bodies, a.prefixes())
	a.classify(issueIDs)
	a.orphans(issueIDs)
	if len(r.Tracked)+len(r.Untracked)+len(r.Orphaned) == 0 {
		r.note("no-match: no open deltas and no orphaned issues in %s", a.base)
	}
}

// classifySection is the empty-input / unclassifiable check on the delta section (kit issue #1111): false stops
// the audit with its stderr line already written.
func (a *audit) classifySection() bool {
	r, d := a.rep, a.doc
	info := retrogrammar.Delta(d)
	if w := d.FenceWarning(); w != "" { // the first read speaks; the secondary reads are quiet
		r.note("%s", strings.TrimSuffix(w, "\n"))
	}
	a.foundSec = info.Found
	if info.Found {
		return true
	}
	// A heading the canonical grammar does not know can still carry a form the shared lib recognises (kit issues
	// #1895 #1932 #1933 #1934 #1938 #1939): the record is dropped ONLY when EVERY unrecognised heading produced items.
	altRows := retrogrammar.AltEntryRows(d)
	altHeads := retrogrammar.AltHeads(d)
	unrec := retrogrammar.UnrecHeadings(d)
	missing := ""
	for _, uh := range unrec {
		if uh != "" && !slices.Contains(altHeads, uh) {
			missing = uh
			break
		}
	}
	if info.UnrecFound && len(unrec) == 0 { // fail closed: an unavailable list keeps the record
		missing = "unavailable"
	}
	switch {
	case info.UnrecFound && len(altRows) > 0 && missing == "":
		return true
	case info.UnrecFound:
		r.note("unclassifiable: proposal-like heading found but not in a countable delta form in %s — needs manual review", a.path)
		return len(altRows) > 0
	}
	r.note("empty-input: no delta section found in %s", a.path)
	return false
}

// openRows reports whether any row can still be open under the review-status (kit issue #1090: dismissed ALWAYS
// closes every row, applied only without PARTIAL).
func (a *audit) openRows() bool {
	switch a.status {
	case "dismissed":
		return false
	case "applied":
		return a.partial
	case "pending", "none", "":
	default:
		a.rep.note("WARN: unrecognised review-status '%s' in %s — treating all rows as open", a.status, a.base)
	}
	return true
}

// collectIDs reads the row ids in the order of the legacy script: table rows, else `### D<N> —` entries, else the
// alternative forms. false stops the audit.
func (a *audit) collectIDs() bool {
	r, d := a.rep, a.doc
	ids := tableIDs(d.Lines)
	if len(ids) == 0 {
		ids = retrogrammar.EntryIDs(d)
		if len(ids) > 0 { // entries whose heading token is not a usable ID (kit issue #1332 N6)
			if w := retrogrammar.EntryWarn(d); w != "" {
				r.note("%s", strings.TrimSuffix(w, "\n"))
			}
		}
	}
	if len(ids) == 0 {
		for _, row := range retrogrammar.AltEntryRows(d) {
			ids = append(ids, row.ID)
		}
		if dups := strings.Join(retrogrammar.DupIDs(ids), " "); dups != "" {
			r.note("unclassifiable: delta items in %s share ids (%s) across two lists — needs manual review", a.path, dups)
			return false
		}
		if len(ids) > 0 && a.foundSec {
			// A canonical heading that produced no items while a list elsewhere did stays reported.
			h, _ := retrogrammar.CanonicalHeading(d)
			if h != "" && !slices.Contains(retrogrammar.AltHeads(d), h) {
				r.note("unclassifiable: delta section found but it produced no items in %s — needs manual review (items elsewhere in the file are reconciled)", a.path)
			}
		}
	}
	if len(ids) == 0 {
		if retrogrammar.HasHonesty(d) {
			r.note("empty-input: delta section found but contains no data rows (honest §18 zero) in %s", a.path)
			return false
		}
		r.note("unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries (nor numbered items directly under the heading, nor '## Delta <ID> —' entries) in %s — needs manual review", a.path)
		return false
	}
	a.allIDs = ids
	return true
}

// buildOpenIDs keeps the ids that are still open: a pipe or a character outside [A-Za-z0-9_-] cannot round-trip
// through the issue signature (typed unclassifiable, like the seeder), and under PARTIAL the marker's shipped and
// dismissed ids are resolved.
func (a *audit) buildOpenIDs() {
	r := a.rep
	for _, id := range a.allIDs {
		if id == "" {
			continue
		}
		if strings.Contains(id, "|") {
			r.note("unclassifiable: row %s of %s has a pipe in its id (id-contains-pipe) — needs manual review", id, a.base)
			continue
		}
		if !retrogrammar.IDSignatureSafe(id) {
			r.note("unclassifiable: row %s of %s has a character outside [A-Za-z0-9_-] in its id (id-not-signature-safe) — needs manual review", id, a.base)
			continue
		}
		if a.partial {
			if slices.Contains(a.shipped, id) {
				continue
			}
			switch retrogrammar.MarkerRowState(a.marker, id) {
			case retrogrammar.RowMalformed:
				r.note("unclassifiable: row %s of %s cannot be told shipped, dismissed or open — the review-status marker carries a DISMISSED: list with no usable id — needs manual review", id, a.base)
				continue
			case retrogrammar.RowDismissed:
				continue
			}
		}
		a.openIDs = append(a.openIDs, id)
	}
}

// prefixes are the signature prefixes an issue of this retro can carry: the registered target name and, for an
// issue created before #1286, the legacy <path basename> (skipped when it equals the registered name or is a
// structural directory), exactly as the seeder's dedup does (kit issue #1304 item 2).
func (a *audit) prefixes() []string {
	out := []string{a.target + "/retros/" + a.base}
	legacy := filepath.Base(filepath.Dir(filepath.Dir(a.path)))
	switch legacy {
	case "corpus", "retros", "", a.target:
	default:
		out = append(out, legacy+"/retros/"+a.base)
	}
	return out
}

func (a *audit) classify(issueIDs []string) {
	r := a.rep
	closedChecked := false
	for _, id := range a.openIDs {
		if slices.Contains(issueIDs, id) {
			r.out("tracked: row %s — open issue found in %s", id, a.base)
			r.Tracked = append(r.Tracked, Delta{Row: id, Retro: a.base})
			continue
		}
		// No OPEN issue is not yet "no issue" (kit issue #1555), but without a closed cache the closed check
		// cannot run: say so instead of reading it as "no closed issue".
		if !closedChecked {
			closedChecked = true
			r.note("closed-lookup: skipped for %s — --issues-cache without --closed-cache; rows with no open issue are not checked against closed issues", a.base)
		}
		r.out("untracked: row %s — no open issue found for this delta in %s", id, a.base)
		r.Untracked = append(r.Untracked, Delta{Row: id, Retro: a.base})
	}
}

// orphans reports the issues whose row is no longer open, with the reason when the marker proves it (kit issue
// #1492): a row merely absent from the retro gets no claim.
func (a *audit) orphans(issueIDs []string) {
	r := a.rep
	for _, id := range issueIDs {
		if slices.Contains(a.openIDs, id) {
			continue
		}
		why := ""
		state := retrogrammar.RowNotPartial
		if a.partial {
			state = retrogrammar.MarkerRowState(a.marker, id)
		}
		switch {
		case a.partial && slices.Contains(a.shipped, id):
			why = " — the retro marker lists it shipped; propose closing the issue (not closed here)"
		case state == retrogrammar.RowDismissed:
			why = " — the retro marker lists it dismissed; propose closing the issue (not closed here)"
		case state == retrogrammar.RowMalformed:
			why = " — marker DISMISSED list malformed; cannot tell"
		case slices.Contains(a.allIDs, id) && (a.status == "applied" || a.status == "dismissed"):
			why = " — the retro review-status is " + a.status + "; propose closing the issue (not closed here)"
		}
		r.out("orphaned: issue for row %s is no longer open in %s%s", id, a.base, why)
		r.Orphaned = append(r.Orphaned, Delta{Row: id, Retro: a.base, Why: strings.TrimPrefix(why, " — ")})
	}
}
