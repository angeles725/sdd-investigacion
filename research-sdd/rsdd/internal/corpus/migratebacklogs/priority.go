package migratebacklogs

import (
	"regexp"
	"strings"
)

// The typed reasons of a row the tool will not guess.
const (
	reasonUnknownPriority = "unknown-priority"
	reasonEmdashOpen      = "emdash-open-row"
	reasonBareClosure     = "bare-closure-word"
	reasonUnknownStatus   = "unknown-status-token"
)

var (
	// reQualifier finds the trailing parenthesised qualifier of a priority: `high (cross-vibra)`. The leftmost
	// match wins, so the blanks in front of the parenthesis belong to it.
	reQualifier = regexp.MustCompile(` *\([^)]*\)$`)
	// reStruck is a priority that was struck through on purpose.
	reStruck = regexp.MustCompile(`^~~(high|medium|low)~~$`)
	// reOpenish are the leading status tokens an em-dash row must not carry.
	reOpenish = regexp.MustCompile(`^(pending|requires-execution|open|queued|blocked)`)
	// reKnownStatus are the leading status tokens the §8b grammar accepts as they are.
	reKnownStatus = regexp.MustCompile(`^(pending|requires-execution)|^blocked-on-[a-z0-9/-]+`)
)

const checkMark = "✅"

func legalTier(q string) bool {
	return q == "high" || q == "medium" || q == "low" || q == "deferred"
}

func mapTier(q string) string {
	switch q {
	case "critical":
		return "high"
	case "med":
		return "medium"
	}
	return q
}

// planPriority is the proposed Priority cell for the trimmed cell p, and the qualifier to move to the end of
// the Status cell. ok is false for a priority the tool will not guess.
func planPriority(p string) (np, decor string, ok bool) {
	q := lower(p)
	if legalTier(q) {
		return q, "", true
	}
	if reStruck.MatchString(q) || strings.HasPrefix(q, "—") {
		return p, "", true
	}
	plain := strings.ReplaceAll(p, "**", "")
	b := lower(plain)
	if b == "low (deferred)" {
		return "deferred", "", true
	}
	if loc := reQualifier.FindStringIndex(b); loc != nil {
		base := mapTier(b[:loc[0]])
		if !legalTier(base) {
			return "", "", false
		}
		// the qualifier is free text (§8b): it keeps the case the author wrote
		return base, strings.TrimLeft(plain[loc[0]:], " "), true
	}
	if m := mapTier(b); legalTier(m) {
		return m, "", true
	}
	return "", "", false
}

// planStatus is the proposed Status cell for the trimmed cell s (empty: no change) and the reason, if any, why
// the row also needs a person. np is the planned Priority cell: an em-dash priority marks a row that is not open.
func planStatus(s, np string) (newStatus, reason string) {
	lead := strings.TrimPrefix(s, "**")
	lead = strings.Replace(lead, "**", "", 1)
	tok := lead
	if i := strings.IndexAny(lead, blanks); i >= 0 {
		tok = lead[:i]
	}
	ltok := lower(tok)
	switch {
	case strings.HasPrefix(np, "—"):
		if reOpenish.MatchString(ltok) {
			return "", reasonEmdashOpen
		}
	case ltok == "open" || ltok == "queued":
		i := strings.Index(s, tok)
		return s[:i] + "pending" + s[i+len(tok):], ""
	case ltok == "covered" || ltok == "closed" || ltok == "done":
		return "", reasonBareClosure
	case !(reKnownStatus.MatchString(ltok) || strings.HasPrefix(s, checkMark) || strings.HasPrefix(ltok, "~~") || strings.HasPrefix(lead, checkMark)):
		return "", reasonUnknownStatus
	}
	return "", ""
}

// rewriteRow plans one data row of a backlog table of the given width (the Status cell is the last one). It
// returns the row to print and the reason a person must look at it. An unknown priority stops the planning: the
// row is printed as it came.
func rewriteRow(r row, width int) (out row, reason string) {
	p := trim(r.cells[0])
	np, decor, ok := planPriority(p)
	if !ok {
		return r, reasonUnknownPriority
	}
	s := trim(r.cells[width-1])
	newStatus, reason := planStatus(s, np)
	if decor != "" {
		if newStatus == "" {
			newStatus = s
		}
		if newStatus != "" {
			newStatus += " "
		}
		newStatus += decor
	}
	out = row{prefix: r.prefix, cells: append([]string(nil), r.cells...), rest: r.rest}
	if np != p {
		out.set(0, np)
	}
	if newStatus != "" {
		out.set(width-1, newStatus)
	}
	return out, reason
}
