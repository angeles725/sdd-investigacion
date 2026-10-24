package grammar

import (
	"regexp"
	"strings"
)

var reMarkerHere = regexp.MustCompile(`^<!--[[:space:]]*review-status:`)

// markerLine is retro_marker_line: the raw first review-status line ANYWHERE in the file, `<!--` after at most
// three spaces, skipping fenced code blocks. Its fence rules are the lib's own, not defence's: an opener may be
// indented by any blanks (spaces or tabs), and a fence still open at EOF FAILS CLOSED, returning the first
// marker-shaped line inside it (kit issues #949, #1304), so MarkerOutOfScope refuses that retro.
func markerLine(d *Doc) string {
	inFence, fch, flen, held := false, byte(0), 0, ""
	for _, line := range bomless(d) {
		s := strings.TrimLeft(line, " \t")
		isMark := isMarkerAt3(line)
		c, n, rest := byte(0), 0, ""
		if s != "" {
			c = s[0]
			n = runLen(s, c)
			rest = s[n:]
		}
		switch {
		case !inFence && (c == '`' || c == '~') && n >= 3 && !(c == '`' && strings.Contains(rest, "`")):
			inFence, fch, flen, held = true, c, n, ""
		case !inFence && isMark:
			return line
		case inFence && c == fch && n >= flen && strings.Trim(rest, " \t\r") == "": // CR tolerated: CRLF files
			inFence, held = false, ""
		case inFence && isMark && held == "":
			held = line
		}
	}
	if inFence { // RETRO_MARKER_LINE_FENCE_UNCLOSED
		return held
	}
	return ""
}

// isMarkerAt3 is `^ ? ? ?<!--[[:space:]]*review-status:` (case-insensitive): a marker not in indented code.
func isMarkerAt3(line string) bool {
	n := runLen(line, ' ')
	return n <= 3 && reMarkerHere.MatchString(lower(line[n:]))
}

// MarkerOutOfScope is retro_marker_out_of_scope (#1099): the file carries a review-status marker that the shared
// scope (MarkerScopeLine) does not see. A retro with no marker anywhere is NOT out of scope.
func MarkerOutOfScope(d *Doc) bool { return MarkerScopeLine(d) == "" && markerLine(d) != "" }
