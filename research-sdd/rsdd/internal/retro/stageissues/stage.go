package stageissues

import (
	"errors"
	"regexp"
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/grammar"
)

var (
	// The first proposal-like heading of the retro, for the unclassifiable records (grep -m1 -iE under LC_ALL=C).
	reHeadingAny   = regexp.MustCompile(`^#{2,4} .*(delta|proposal|propuesta)`)
	reHeadingDelta = regexp.MustCompile(`^## .*(delta|propuesta)`)
)

// firstHeading is `grep -m1 -iE <re>` over the raw retro lines ("" when none); re is matched on the lowercased
// line, the ASCII case folding of the C locale.
func (a *app) firstHeading(re *regexp.Regexp) string {
	for _, l := range a.doc.Raw {
		if re.MatchString(lowerASCII(l)) {
			return l
		}
	}
	return ""
}

func headOr(h string) string {
	if h == "" {
		return "<heading not located>"
	}
	return h
}

// stage is everything after the retro, the kit and the target are known: the review-status gate, the delta
// section verdicts, the parse, and the staging loop.
func (a *app) stage() int {
	d, err := grammar.Read(a.retro)
	if err != nil {
		if errors.Is(err, grammar.ErrAbsentInput) {
			a.errf("absent-input: retro not found: %s\n", a.retro)
		} else {
			a.errf("degraded: retro not readable: %s\n", a.retro)
		}
		return 1
	}
	a.doc = d
	// retro_marker_scope_line is the ONE marker scope reconcile-issues.sh, retro-gate.sh and sweep-retros.sh
	// share: the leading block, tolerating exactly one H1 line at the top.
	a.markerLine = grammar.MarkerScopeLine(d)
	// An empty scope-scan result does NOT necessarily mean "no marker": a whole-file scan may still find one outside
	// the leading-block scope. Conflating that with "genuinely absent" was the #1048-#1089 fail-open shape (status
	// read as "", every row seeded). Fail CLOSED: refuse to seed and say why (kit issue #1099).
	if a.markerLine == "" && grammar.MarkerOutOfScope(d) {
		a.errf("out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in %s — refusing to seed (kit issue #1099); move the marker into the leading block\n", a.retroBase)
		return 0
	}
	status := grammar.StatusFromMarkerLine(a.markerLine)
	// PARTIAL is a STATUS TOKEN, detected only in the marker's STRUCTURED segment (kit issue #1090), never a
	// case-insensitive whole-line grep, which let prose like "(P1 partial)" false-positive.
	if grammar.MarkerIsPartial(a.markerLine) {
		a.isPartial = true
		if raw := grammar.ShippedRaw(a.markerLine); raw != "" {
			ids, err := grammar.ShippedIDs(raw)
			if err != nil {
				a.errf("degraded: the review-status marker of %s lists a shipped: range too large to expand (%v)\n", a.retroBase, err)
				return 1
			}
			a.shipped = ids
		}
	}
	// Fully applied/dismissed with no PARTIAL marker is an early no-match. 'dismissed' ALWAYS means zero open rows:
	// even a structured PARTIAL token on a dismissed marker cannot reopen its rows (kit issue #1090).
	switch status {
	case "dismissed":
		a.errf("no-match: retro is 'dismissed' — all rows shipped\n")
		a.outf("unclassifiable-items: 0 (retro-closed: dismissed)\n")
		return 0
	case "applied":
		if !a.isPartial {
			a.outf("unclassifiable-items: 0 (retro-closed: applied)\n")
			a.errf("no-match: retro is 'applied' — all rows shipped\n")
			return 0
		}
	case "pending", "none", "":
	default:
		a.errf("WARN: unrecognised review-status '%s' — treating all rows as open\n", status)
	}

	uncEarly := false
	info := grammar.Delta(d)
	if w := d.FenceWarning(); w != "" { // the first read (delta_info) speaks; the secondary reads are quiet
		a.errf("%s", w)
	}
	if !info.Found {
		// A retro whose only proposal-like heading the parser cannot classify (a hyphenated "kit-delta" mid-heading,
		// a standalone "### Proposals") must never be a confident empty-input: that silently hides real proposals
		// from the backlog. Kit issues #1895 #1932 #1933 #1934 #1938 #1939: a heading the canonical grammar does not
		// know can still carry a delta form the shared lib recognises. The unclassifiable record is suppressed ONLY
		// when EVERY unrecognised heading produced items.
		altEarly := grammar.AltEntryRows(d)
		altHeads := grammar.AltHeads(d)
		missing := ""
		unrecList := grammar.UnrecHeadings(d)
		for _, uh := range unrecList {
			if uh != "" && !slices.Contains(altHeads, uh) {
				missing = uh
				break
			}
		}
		// Fail closed: delta_info saw an unrecognised heading but the list is empty -> nothing is proven to have
		// produced items, so the record is kept.
		if info.UnrecFound && len(unrecList) == 0 {
			missing = info.UnrecHeading
			if missing == "" {
				missing = "<unrecognised heading list unavailable>"
			}
		}
		switch {
		case info.UnrecFound && len(altEarly) > 0 && missing == "":
			// every unrecognised heading produced delta items: the parse below classifies them
		case info.UnrecFound:
			a.errf("unclassifiable: proposal-like heading found but not in a countable delta form in %s — needs manual review, no issue auto-staged\n", a.retro)
			h := missing
			if h == "" {
				h = a.firstHeading(reHeadingAny)
			}
			a.uncAdd(true, a.uncLineOf(h), headOr(h), "proposal-like heading not in a countable delta form")
			if len(altEarly) == 0 {
				uncEarly = true
			}
		default:
			a.errf("empty-input: no delta section found in %s\n", a.retro)
			a.outf("unclassifiable-items: 0 (empty-input: no delta section and no proposal-like heading)\n")
			return 0
		}
	}

	var rows []grammar.Row
	if !uncEarly {
		rows = tableRows(d.Lines)
		// no table rows -> the doctrine-valid `### D<N> —` entry form (kit issue #1332 N1)
		if len(rows) == 0 {
			rows = grammar.EntryRows(d)
			if len(rows) > 0 {
				a.errf("%s", grammar.EntryWarn(d)) // entries whose heading token is not a usable ID (N6)
			}
		}
		// no table and no entry -> the fleet's other real forms (numbered prose items, `## Delta <ID> —` entries, a
		// `### Proposals` list), classified by the shared grammar lib; the id is the item number / the delta id.
		if len(rows) == 0 {
			rows = grammar.AltEntryRows(d)
			if len(rows) > 0 {
				ids := make([]string, len(rows))
				for i, r := range rows {
					ids[i] = r.ID
				}
				// A numbered list restarts at 1: two lists would share ids and the signature (keyed on the id) would
				// merge them. Typed refusal, not a silent loss.
				if dups := strings.Join(grammar.DupIDs(ids), " "); dups != "" {
					a.errf("unclassifiable: delta items in %s share ids (%s) across two lists — needs manual review, no issue auto-staged\n", a.retro, dups)
					h := a.firstHeading(reHeadingAny)
					a.uncAdd(true, a.uncLineOf(h), headOr(h), "delta items share ids ("+dups+") across two lists")
					rows, uncEarly = nil, true
				} else {
					// The first delta heading of the file must be one that produced items; else it stays unclassifiable.
					h, _ := grammar.CanonicalHeading(d)
					if info.Found && h != "" && !slices.Contains(grammar.AltHeads(d), h) {
						a.errf("unclassifiable: delta section found but it produced no items in %s — needs manual review (items elsewhere in the file are staged)\n", a.retro)
						a.uncAdd(true, a.uncLineOf(h), h, "delta section has neither row-table rows nor '### D<N> —' entries nor numbered items")
					}
				}
			}
		}
		if len(rows) == 0 && !uncEarly {
			// An HONEST §18 zero first (kit issue #1129): a canonical section whose only body content is the accepted
			// honesty phrase has genuinely nothing to count.
			if grammar.HasHonesty(d) {
				a.errf("empty-input: delta section found but contains no data rows (honest §18 zero) in %s\n", a.retro)
				a.outf("unclassifiable-items: 0 (empty-input: honest §18 zero, no data rows)\n")
				return 0
			}
			// A section WAS found, so this is not "empty" (kit issue #1111): it holds none of the forms this parser
			// can auto-stage from, and it is not a declared honest zero either.
			a.errf("unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries (nor numbered items directly under the heading, nor '## Delta <ID> —' entries) in %s — needs manual review, no issue auto-staged\n", a.retro)
			h := a.firstHeading(reHeadingDelta)
			a.uncAdd(true, a.uncLineOf(h), headOr(h), "delta section has neither row-table rows nor '### D<N> —' entries nor numbered items")
			uncEarly = true
		}
	}

	// Section-level unclassifiable (the parse was skipped): report, propose the tracker, summarise, exit.
	if uncEarly {
		a.unclassifiable += a.uncN
		a.uncReport("section-level")
		a.printSummaries()
		return a.finalExit()
	}

	for _, r := range rows {
		a.stageRow(r)
	}

	// Summary and no-match detection when all rows were shipped
	if a.open == 0 && a.skippedShipped > 0 && a.skippedWrongKit == 0 {
		if a.skippedDismissed > 0 {
			a.errf("no-match: delta section found but all rows are shipped or dismissed (skipped: %d)\n", a.skippedShipped)
		} else {
			a.errf("no-match: delta section found but all rows are shipped (skipped: %d)\n", a.skippedShipped)
		}
	}
	a.uncReport(sprintf("none: %d row(s) examined", a.open+a.skippedShipped+a.skippedWrongKit+a.unclassifiable))
	a.printSummaries()
	return a.finalExit()
}

// printSummaries: the counter-reset proposal and the --apply summary lines.
func (a *app) printSummaries() {
	a.printCounterReset()
	if !a.apply {
		return
	}
	// 'failed=' is appended LAST so existing parsers that read the earlier fields are unaffected.
	a.outf("summary: created=%d skipped-duplicate=%d skipped-shipped=%d skipped-wrong-kit=%d unclassifiable=%d unknown-outcome=%d failed=%d\n",
		a.created, a.skippedDedup, a.skippedShipped, a.skippedWrongKit, a.unclassifiable, a.summaryUnknown, a.failed)
	// Kit issue #1705: the outcome triad is its OWN line, so the summary: line above stays byte-compatible.
	a.outf("mutation-summary: confirmed=%d no_write=%d unknown=%d\n", a.mutConfirmed, a.mutNoWrite, a.mutUnknown)
	// Kit issue #1708: occurrence comments are their own line too (a row commented on N issues counts N).
	a.outf("occurrence-summary: commented=%d already-present=%d\n", a.occCommented, a.occPresent)
	if a.mutUnknown > 0 {
		a.errf("mutation-unknown: %d row(s) with an unconfirmed mutation outcome — NOT retried; verify on GitHub before re-running\n", a.mutUnknown)
	}
}

// finalExit: exit 2 when any create failed (partial failure must not look like success), exit 3 when none failed but
// a row's mutation outcome is unknown (kit issue #1705): an unconfirmed write is never a green run, never retried.
func (a *app) finalExit() int {
	switch {
	case a.failed > 0:
		return 2
	case a.mutUnknown > 0:
		return 3
	}
	return 0
}
