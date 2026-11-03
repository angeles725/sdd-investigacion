package corrections

import "strings"

// Byte-level equivalents of the extractor's line and verb regexps. Go's backtracking engine clears a visited
// bitmap proportional to the INPUT length on every call, so a regexp tried on a long line costs O(length) even when
// it is anchored and fails at the first byte (kit issue #2635). Each function here decides exactly what its regexp
// does (scanfast_test.go pins them against the regexps over generated inputs) in time bounded by the match.

func isBlankByte(c byte) bool { return c == ' ' || c == '\t' }

// skipBlanks is the index of the first byte of s that is not a space or tab.
func skipBlanks(s string) int {
	i := 0
	for i < len(s) && isBlankByte(s[i]) {
		i++
	}
	return i
}

// quoteStripEnd is the length of reQuoteStrip's match (`^[ \t]*(>[ \t]*)+`), 0 when it does not match: stripping
// nothing and not matching are the same edit.
func quoteStripEnd(s string) int {
	i := skipBlanks(s)
	if i >= len(s) || s[i] != '>' {
		return 0
	}
	for i < len(s) && s[i] == '>' {
		i++
		i += skipBlanks(s[i:])
	}
	return i
}

// isBlankLine is reBlank (`^[ \t]*$`).
func isBlankLine(s string) bool { return skipBlanks(s) == len(s) }

// startsBlock is reHeading, reTableRow or reListHead: the line opens a new logical unit.
func startsBlock(s string) bool {
	i := skipBlanks(s)
	if i >= len(s) {
		return false
	}
	switch c := s[i]; {
	case c == '#' || c == '|':
		return true
	case c == '-' || c == '*' || c == '+':
		return i+1 < len(s) && isBlankByte(s[i+1])
	case c >= '0' && c <= '9':
		j := i
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		return j+1 < len(s) && (s[j] == '.' || s[j] == ')') && isBlankByte(s[j+1])
	}
	return false
}

// isNonWordByte is the byte class of nonWord.
func isNonWordByte(c byte) bool {
	return c <= 0x2f || c >= 0x3a && c <= 0x40 || c >= 0x5b && c <= 0x5e || c == 0x60 || c >= 0x7b && c <= 0x7f
}

// verbAt is the verb word starting at s[i:] ("corrects" or corrig[a-z]*), or "" when none starts there.
func verbAt(s string, i int) string {
	t := s[i:]
	if strings.HasPrefix(t, "corrects") {
		return "corrects"
	}
	if !strings.HasPrefix(t, "corrig") {
		return ""
	}
	j := len("corrig")
	for j < len(t) && t[j] >= 'a' && t[j] <= 'z' {
		j++
	}
	return t[:j]
}

// matchVerb is match(reVerb, s): `(^|nonWord)(corrects|corrig[a-z]*)`, leftmost-longest, as (start, length).
func matchVerb(s string) (rstart, rlength int) {
	from := 0
	for {
		k := strings.Index(s[from:], "corr")
		if k < 0 {
			return 0, -1
		}
		i := from + k
		if i == 0 || isNonWordByte(s[i-1]) {
			if v := verbAt(s, i); v != "" {
				if i == 0 {
					return 1, len(v)
				}
				return i, len(v) + 1
			}
		}
		from = i + 1
	}
}

// endsWord reports whether s, minus its mandatory trailing blank run, ends with one of words at a word boundary
// (the start of s or a non-word byte before it): the shape of reSe and reNegPre (`(^|nonWord)(words)[ \t]+$`).
func endsWord(s string, words ...string) bool {
	e := len(s)
	for e > 0 && isBlankByte(s[e-1]) {
		e--
	}
	if e == len(s) {
		return false
	}
	for _, w := range words {
		if strings.HasSuffix(s[:e], w) && (e == len(w) || isNonWordByte(s[e-len(w)-1])) {
			return true
		}
	}
	return false
}
