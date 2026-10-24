package grammar

import (
	"regexp"
	"slices"
	"strings"
)

// RowState is retro_marker_row_state's typed answer for one row of a PARTIAL retro (kit issue #1944).
type RowState string

// The five answers, spelled as bash prints them.
const (
	RowShipped    RowState = "shipped"     // the id is in the marker's shipped: list
	RowDismissed  RowState = "dismissed"   // the id is in a DISMISSED: list: resolved, never open, never seeded
	RowOpen       RowState = "open"        // neither (a DEFERRED or unlisted id included)
	RowNotPartial RowState = "not-partial" // the marker is not PARTIAL: its status closes the whole retro
	RowMalformed  RowState = "malformed"   // empty line or id, or an unreadable DISMISSED: list
)

var (
	reInnerParen  = regexp.MustCompile(`[[:space:]]*\([^()]*\)`)
	reDismissedSg = regexp.MustCompile(`(^|[^A-Za-z])DISMISSED:[^;]*`)
)

// MarkerRowState is retro_marker_row_state. An id in both lists reads shipped (it did ship). Ids compare as
// whole strings. A list Go refuses (ErrRangeTooLarge, finding F4) answers malformed.
func MarkerRowState(line, rid string) RowState {
	if line == "" || rid == "" {
		return RowMalformed
	}
	if !MarkerIsPartial(line) {
		return RowNotPartial
	}
	shipped, err := ShippedIDs(ShippedRaw(line))
	if err != nil {
		return RowMalformed
	}
	if slices.Contains(shipped, rid) {
		return RowShipped
	}
	dismissed, malformed, err := dismissedIDs(line)
	switch {
	case err != nil || malformed:
		return RowMalformed
	case slices.Contains(dismissed, rid):
		return RowDismissed
	}
	return RowOpen
}

// dismissedIDs is retro_marker_dismissed_ids: the ids of EVERY `DISMISSED:` segment (the case-sensitive token,
// not after a letter; a segment ends at `;`), joined and normalised like shipped ids. Parentheticals are removed
// innermost first BEFORE the cut at `-->`, so a `;` or `-->` inside "(reason; more)" truncates nothing.
// malformed is the bash rc 3: the keyword is present but no id survives (`DISMISSED: ;`).
func dismissedIDs(line string) (ids []string, malformed bool, err error) {
	if line == "" {
		return nil, false, nil
	}
	lines := strings.Split(afterFirst(line, "review-status:"), "\n") // sed and grep work per line
	for i, l := range lines {
		for loc := reInnerParen.FindStringIndex(l); loc != nil; loc = reInnerParen.FindStringIndex(l) {
			l = l[:loc[0]] + l[loc[1]:]
		}
		lines[i] = l
	}
	body, _, _ := strings.Cut(strings.Join(lines, "\n"), "-->")
	var segs []string
	for _, l := range strings.Split(body, "\n") {
		for _, seg := range reDismissedSg.FindAllString(l, -1) {
			segs = append(segs, afterFirst(seg, "DISMISSED:"))
		}
	}
	if len(segs) == 0 {
		return nil, false, nil
	}
	ids, err = ShippedIDs(strings.Join(segs, ", "))
	return ids, err == nil && len(ids) == 0, err
}
