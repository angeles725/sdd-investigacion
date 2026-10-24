package grammar

import (
	"regexp"
	"strings"
)

// Review-status markers (lib/retro-status.sh, METHODOLOGY §18): the `<!-- review-status: … -->` line that closes
// or opens a retro, and the leading-block opt-outs. The marker readers live in this package because they read the
// same Doc (one read, typed absent/unreadable errors) with the same byte helpers as the delta grammar.
//
// Every file reader works on the lines with a UTF-8 BOM removed from line 1 (_retro_status_strip_bom, #1125).
// "Leading block" is the run of `<!--` comment lines and blank lines before the first other line. Matching is
// ASCII case-insensitive (the bash grep -i under LC_ALL=C): lines are folded with lower first.

var (
	reStatusWord   = regexp.MustCompile(`<!--[[:space:]]*review-status:[[:space:]]*[a-z]+`)
	reStatusMarker = regexp.MustCompile(`<!--[[:space:]]*review-status:`)
	reScopeMarker  = regexp.MustCompile(`^[[:space:]]*<!--[[:space:]]*review-status:`)
	reExcluded     = regexp.MustCompile(`^[[:space:]]*<!--[[:space:]]*kit-retro:[[:space:]]*exclude[[:space:]]*-->[[:space:]]*$`)
	reWaived       = regexp.MustCompile(`^[[:space:]]*<!--[[:space:]]*retro-waived:[[:space:]]*[^[:space:]>][^>]*-->[[:space:]]*$`)
	reBareMarker   = regexp.MustCompile(`^[[:space:]]*review-status:`)
)

// StatusFromMarkerLine is retro_status_from_marker_line: the lowercased status word of the first
// `<!-- review-status: <word>` on the line, "" when there is none. A marker line is one line.
func StatusFromMarkerLine(line string) string {
	_, word, found := strings.Cut(lower(grepO(line, reStatusWord)), "review-status:")
	if !found {
		return ""
	}
	return trimLeftSpace(word)
}

// ReviewStatus is retro_review_status: the status word of the first review-status comment in the LEADING
// BLOCK, with no H1 tolerance (a heading ends the block). "" when there is none.
func ReviewStatus(d *Doc) string {
	for _, l := range leadingComments(bomless(d), false) {
		if reStatusMarker.MatchString(lower(l)) {
			return StatusFromMarkerLine(l)
		}
	}
	return ""
}

// MarkerScopeLine is retro_marker_scope_line (#945): the raw first review-status line of the leading block,
// where line 1 may be one H1 (`#` then a non-`#`, or a bare `#`) and a comment opens with `<!--` after at
// most three spaces (a deeper or tab indent is indented code, #1130). "" when there is none in scope.
func MarkerScopeLine(d *Doc) string {
	for _, l := range leadingComments(bomless(d), true) {
		if reScopeMarker.MatchString(lower(l)) {
			return l
		}
	}
	return ""
}

// IsExcluded is retro_is_excluded: the leading block holds exactly `<!-- kit-retro: exclude -->` on a line.
func IsExcluded(d *Doc) bool { return anyLower(leadingComments(bomless(d), false), reExcluded) }

// IsWaived is retro_is_waived: the leading block holds a whole-line `<!-- retro-waived: <text> -->`.
func IsWaived(d *Doc) bool { return anyLower(leadingComments(bomless(d), false), reWaived) }

// HasBareMarker is retro_has_bare_marker: one of the first 10 lines is a bare `review-status:` (malformed: not
// wrapped in a comment).
func HasBareMarker(d *Doc) bool {
	lines := bomless(d)
	return anyLower(lines[:min(len(lines), 10)], reBareMarker)
}

// bomless is d.Raw with a leading UTF-8 BOM removed from line 1.
func bomless(d *Doc) []string {
	if len(d.Raw) == 0 || !strings.HasPrefix(d.Raw[0], "\xef\xbb\xbf") {
		return d.Raw
	}
	out := append([]string(nil), d.Raw...)
	out[0] = out[0][3:]
	return out
}

// leadingComments returns the comment lines of the leading block. scoped is the #945 scope: one H1 tolerated on
// line 1 and a comment indented by at most three spaces; otherwise any blank indent opens a comment.
func leadingComments(lines []string, scoped bool) []string {
	var out []string
	for i, l := range lines {
		switch {
		case scoped && i == 0 && isH1(l):
		case scoped && runLen(l, ' ') <= 3 && strings.HasPrefix(l[runLen(l, ' '):], "<!--"):
			out = append(out, l)
		case !scoped && strings.HasPrefix(trimLeftSpace(l), "<!--"):
			out = append(out, l)
		case trimLeftSpace(l) == "":
		default:
			return out
		}
	}
	return out
}

// isH1 is the scope's line-1 heading: `#` after optional blanks, then nothing or a non-`#` byte (the awk
// `#[^#]` and `#[[:space:]]*$` rules; the second only adds the bare `#`).
func isH1(l string) bool {
	s := trimLeftSpace(l)
	return strings.HasPrefix(s, "#") && (len(s) == 1 || s[1] != '#')
}

func anyLower(lines []string, re *regexp.Regexp) bool {
	for _, l := range lines {
		if re.MatchString(lower(l)) {
			return true
		}
	}
	return false
}
