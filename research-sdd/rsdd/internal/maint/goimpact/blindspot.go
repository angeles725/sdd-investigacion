package goimpact

import "regexp"

var binNameRe = regexp.MustCompile(`RSDD_(REAL_)?BIN\b`)

// blindSpotReason is the unclassifiable reason for a file that names RSDD_BIN or RSDD_REAL_BIN in code (not a
// comment) yet resolves no call to a recovered command (C9). Such a file hands the binary to something else (a
// shim, an env prefix, a function), so the commands it really reaches are invisible to the enumerator: a Go
// blind spot, never silently skipped. A file with at least one resolved call is not a blind spot.
func blindSpotReason(text string, resolved int) string {
	if resolved > 0 {
		return ""
	}
	for _, line := range logicalLines(text) {
		for _, t := range lex(line) {
			if !t.sep && binNameRe.MatchString(t.text) {
				return "names RSDD_BIN outside a recognised call form"
			}
		}
	}
	return ""
}
