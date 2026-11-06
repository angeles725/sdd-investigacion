package cleancheck

import (
	"strings"
	"unicode/utf8"
)

// bracket matches c against the bracket expression starting at p[i]. valid is false when it is not terminated (the
// [ is then an ordinary character); next is the index after the closing ].
func bracket(p []rune, i int, c rune) (match bool, next int, valid bool) {
	j := i + 1
	negate := false
	if j < len(p) && (p[j] == '!' || p[j] == '^') {
		negate = true
		j++
	}
	first := true
	for j < len(p) {
		if p[j] == ']' && !first {
			return match != negate, j + 1, true
		}
		first = false
		lo, w, class, isClass := bracketItem(p, j)
		switch {
		case isClass:
			if inSpans(class, c) {
				match = true
			}
			j += w
		case j+w+1 < len(p) && p[j+w] == '-' && p[j+w+1] != ']':
			hi, w2, _, _ := bracketItem(p, j+w+1)
			if lo <= c && c <= hi {
				match = true
			}
			j += w + 1 + w2
		default:
			if lo == c {
				match = true
			}
			j += w
		}
	}
	return false, 0, false
}

// bracketItem reads one element at p[j]: a character (a backslash quotes the next one), or a [:class:]. An unknown
// class name is an empty class (bash: it matches nothing).
func bracketItem(p []rune, j int) (r rune, width int, class []span, isClass bool) {
	if rest := string(p[j:]); strings.HasPrefix(rest, "[:") {
		if end := strings.Index(rest[2:], ":]"); end >= 0 {
			name := rest[2 : 2+end]
			return 0, 4 + utf8.RuneCountInString(name), classes[name], true
		}
	}
	if p[j] == '\\' && j+1 < len(p) {
		return p[j+1], 2, nil, false
	}
	return p[j], 1, nil, false
}

// inSpans reports whether c lies in one of the spans.
func inSpans(spans []span, c rune) bool {
	for _, s := range spans {
		if s.lo <= c && c <= s.hi {
			return true
		}
	}
	return false
}
