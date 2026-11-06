// Package textlog holds the rule a ported grep-based log reader needs to keep the legacy verdict: GNU grep reads a
// file holding a NUL byte as binary and prints none of its lines, so a legacy script that greps a log for a line
// finds nothing in such a log. A Go port that splits it into text lines would accept what the script rejected.
//
// Measured with GNU grep 3.11 under LC_ALL=C and LC_ALL=C.UTF-8 (2026-11-06): a NUL before or after the matching
// line hides the match; invalid UTF-8 does NOT make grep skip a log (on a line that is not output it is ignored, and
// on the line itself the pattern fails as it does in Go's regexp), so it is no part of this rule.
//
// Intended divergence, stricter than grep: grep decides per read buffer, so in a log larger than its buffer a match
// that precedes the first NUL-holding buffer is still printed; Binary judges the whole file and rejects it.
package textlog

import "bytes"

// Binary reports whether b holds a NUL byte, the case in which grep would print no line of it.
func Binary(b []byte) bool {
	return bytes.IndexByte(b, 0) >= 0
}
