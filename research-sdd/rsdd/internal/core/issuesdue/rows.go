package issuesdue

import (
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The row readers of Read, one per step of the legacy audit_retro, each in the legacy order of messages.

// classifySection is the empty-input / unclassifiable check on the delta section (kit issue #1111): false stops
// the audit with its stderr line already written.
func (a *Retro) classifySection(sink Sink) bool {
	d := a.Doc
	info := retrogrammar.Delta(d)
	if w := d.FenceWarning(); w != "" { // the first read speaks; the secondary reads are quiet
		sink.Note("%s", strings.TrimSuffix(w, "\n"))
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
		sink.Note("unclassifiable: proposal-like heading found but not in a countable delta form in %s — needs manual review", a.Path)
		return len(altRows) > 0
	}
	sink.Note("empty-input: no delta section found in %s", a.Path)
	return false
}

// openRows reports whether any row can still be open under the review-status (kit issue #1090: dismissed ALWAYS
// closes every row, applied only without PARTIAL).
func (a *Retro) openRows(sink Sink) bool {
	switch a.Status {
	case "dismissed":
		return false
	case "applied":
		return a.Partial
	case "pending", "none", "":
	default:
		sink.Note("WARN: unrecognised review-status '%s' in %s — treating all rows as open", a.Status, a.Base)
	}
	return true
}

// collectIDs reads the row ids in the order of the legacy script: table rows, else `### D<N> —` entries, else the
// alternative forms. false stops the audit.
func (a *Retro) collectIDs(sink Sink) bool {
	d := a.Doc
	ids := tableIDs(d.Lines)
	if len(ids) == 0 {
		ids = retrogrammar.EntryIDs(d)
		if len(ids) > 0 { // entries whose heading token is not a usable ID (kit issue #1332 N6)
			if w := retrogrammar.EntryWarn(d); w != "" {
				sink.Note("%s", strings.TrimSuffix(w, "\n"))
			}
		}
	}
	if len(ids) == 0 {
		for _, row := range retrogrammar.AltEntryRows(d) {
			ids = append(ids, row.ID)
		}
		if dups := strings.Join(retrogrammar.DupIDs(ids), " "); dups != "" {
			sink.Note("unclassifiable: delta items in %s share ids (%s) across two lists — needs manual review", a.Path, dups)
			return false
		}
		if len(ids) > 0 && a.foundSec {
			// A canonical heading that produced no items while a list elsewhere did stays reported.
			h, _ := retrogrammar.CanonicalHeading(d)
			if h != "" && !slices.Contains(retrogrammar.AltHeads(d), h) {
				sink.Note("unclassifiable: delta section found but it produced no items in %s — needs manual review (items elsewhere in the file are reconciled)", a.Path)
			}
		}
	}
	if len(ids) == 0 {
		if retrogrammar.HasHonesty(d) {
			sink.Note("empty-input: delta section found but contains no data rows (honest §18 zero) in %s", a.Path)
			return false
		}
		sink.Note("unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries (nor numbered items directly under the heading, nor '## Delta <ID> —' entries) in %s — needs manual review", a.Path)
		return false
	}
	a.AllIDs = ids
	return true
}

// buildOpenIDs keeps the ids that are still open: a pipe or a character outside [A-Za-z0-9_-] cannot round-trip
// through the issue signature (typed unclassifiable, like the seeder), and under PARTIAL the marker's shipped and
// dismissed ids are resolved.
func (a *Retro) buildOpenIDs(sink Sink) {
	for _, id := range a.AllIDs {
		if id == "" {
			continue
		}
		if strings.Contains(id, "|") {
			sink.Note("unclassifiable: row %s of %s has a pipe in its id (id-contains-pipe) — needs manual review", id, a.Base)
			continue
		}
		if !retrogrammar.IDSignatureSafe(id) {
			sink.Note("unclassifiable: row %s of %s has a character outside [A-Za-z0-9_-] in its id (id-not-signature-safe) — needs manual review", id, a.Base)
			continue
		}
		if a.Partial {
			if slices.Contains(a.Shipped, id) {
				continue
			}
			switch retrogrammar.MarkerRowState(a.Marker, id) {
			case retrogrammar.RowMalformed:
				sink.Note("unclassifiable: row %s of %s cannot be told shipped, dismissed or open — the review-status marker carries a DISMISSED: list with no usable id — needs manual review", id, a.Base)
				continue
			case retrogrammar.RowDismissed:
				continue
			}
		}
		a.OpenIDs = append(a.OpenIDs, id)
	}
}
