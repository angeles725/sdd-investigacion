package goimpact

import "strings"

// subst is a command substitution found inside a word: `$( ... )` or a backtick pair. end is the index of its
// closer; a substitution that never closes has ok false.
type subst struct {
	body string
	end  int
	ok   bool
}

// substAt reports whether a substitution opens at s[i], and reads it. The body may nest substitutions and
// quotes, which are skipped here and lexed later as their own context.
func substAt(s string, i int) (subst, bool) {
	if strings.HasPrefix(s[i:], "$(") {
		end, ok := closeParen(s, i+2)
		if !ok {
			return subst{}, true
		}
		return subst{body: s[i+2 : end], end: end, ok: true}, true
	}
	if s[i] != '`' {
		return subst{}, false
	}
	for j := i + 1; j < len(s); j++ {
		switch s[j] {
		case '\\':
			j++
		case '`':
			return subst{body: s[i+1 : j], end: j, ok: true}, true
		}
	}
	return subst{}, true
}

// closeParen returns the index of the ')' that closes a substitution whose body starts at i, skipping quoted
// text and nested substitutions.
func closeParen(s string, i int) (int, bool) {
	depth := 1
	for ; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '\'':
			end := strings.IndexByte(s[i+1:], '\'')
			if end == -1 {
				return 0, false
			}
			i += end + 1
		case '"':
			end, ok := closeDouble(s, i+1)
			if !ok {
				return 0, false
			}
			i = end
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i, true
			}
		}
	}
	return 0, false
}

// closeDouble returns the index of the '"' that closes a double-quoted text starting at i, skipping escapes
// and nested substitutions.
func closeDouble(s string, i int) (int, bool) {
	for ; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '"':
			return i, true
		case '$':
			if strings.HasPrefix(s[i:], "$(") {
				end, ok := closeParen(s, i+2)
				if !ok {
					return 0, false
				}
				i = end
			}
		}
	}
	return 0, false
}
