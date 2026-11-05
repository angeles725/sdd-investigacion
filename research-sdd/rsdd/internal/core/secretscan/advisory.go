package secretscan

import (
	"unicode/utf8"
)

// The legacy advisory scan used PCRE:
//
//	KWID    = (?<![A-Za-z0-9])(?:password|passwd|secret|api[_-]?key|apikey|token)(?![A-Za-z])[A-Za-z0-9_]*
//	value   = KWID\s*[=:]\s*["']?\K[^"';,\s]+      (grep -oiP, first match per line)
//
// RE2 has no lookaround, so advisoryValue walks the line by hand. Under /i PCRE in UTF mode also folds U+017F (long
// s) to s and U+212A (Kelvin sign) to k, so a homoglyph spelling of a keyword still matches; foldRune keeps that.

// foldRune lower-cases an ASCII letter and folds the two non-ASCII letters that PCRE's caseless UTF matching equates
// with ASCII ones.
func foldRune(r rune) rune {
	switch {
	case r >= 'A' && r <= 'Z':
		return r + ('a' - 'A')
	case r == 0x17F:
		return 's'
	case r == 0x212A:
		return 'k'
	}
	return r
}

func isAlnum(b byte) bool {
	return b >= '0' && b <= '9' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z'
}

// isLetterRune is [A-Za-z] under /i: the ASCII letters plus the two folded letters.
func isLetterRune(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r == 0x17F || r == 0x212A
}

// isSpace is PCRE \s without UCP: space, \t, \n, \v, \f, \r.
func isSpace(b byte) bool { return b == ' ' || b >= '\t' && b <= '\r' }

// matchWord matches word (lower case) at line[i:] case-insensitively and returns the index after it.
func matchWord(line []byte, i int, word string) (int, bool) {
	for k := 0; k < len(word); k++ {
		if i >= len(line) {
			return 0, false
		}
		r, w := utf8.DecodeRune(line[i:])
		if foldRune(r) != rune(word[k]) {
			return 0, false
		}
		i += w
	}
	return i, true
}

// matchAPIKey matches api[_-]?key, backtracking the optional separator as PCRE does.
func matchAPIKey(line []byte, i int) (int, bool) {
	j, ok := matchWord(line, i, "api")
	if !ok {
		return 0, false
	}
	if j < len(line) && (line[j] == '_' || line[j] == '-') {
		if e, ok := matchWord(line, j+1, "key"); ok {
			return e, true
		}
	}
	return matchWord(line, j, "key")
}

// keywordEnd returns the end of the keyword that starts at i, when one does and the next character is not a letter.
func keywordEnd(line []byte, i int) (int, bool) {
	end, ok := matchAPIKey(line, i)
	for _, w := range advisoryKeywords {
		if ok {
			break
		}
		end, ok = matchWord(line, i, w)
	}
	if !ok {
		return 0, false
	}
	if end < len(line) {
		if r, _ := utf8.DecodeRune(line[end:]); isLetterRune(r) {
			return 0, false
		}
	}
	return end, true
}

// skipIdent consumes [A-Za-z0-9_]* (plus the two folded letters) from i.
func skipIdent(line []byte, i int) int {
	for i < len(line) {
		r, w := utf8.DecodeRune(line[i:])
		if !(r < utf8.RuneSelf && (isAlnum(byte(r)) || r == '_') || r == 0x17F || r == 0x212A) {
			break
		}
		i += w
	}
	return i
}

func skipSpace(line []byte, i int) int {
	for i < len(line) && isSpace(line[i]) {
		i++
	}
	return i
}

// valueAt extracts `\s*["']?\K[^"';,\s]+` from i, the part after the assignment operator.
func valueAt(line []byte, i int) ([]byte, bool) {
	i = skipSpace(line, i)
	if i < len(line) && (line[i] == '"' || line[i] == '\'') {
		i++
	}
	start := i
	for i < len(line) && !isSpace(line[i]) && line[i] != '"' && line[i] != '\'' && line[i] != ';' && line[i] != ',' {
		i++
	}
	if i == start {
		return nil, false
	}
	return line[start:i], true
}

// advisoryValue returns the value of the first keyword assignment on the line that has one (a keyword whose
// assignment has no value is skipped, as PCRE moves to the next start position).
func advisoryValue(line []byte) ([]byte, bool) {
	for i := 0; i < len(line); i++ {
		if i > 0 && isAlnum(line[i-1]) {
			continue
		}
		end, ok := keywordEnd(line, i)
		if !ok {
			continue
		}
		j := skipSpace(line, skipIdent(line, end))
		if j >= len(line) || (line[j] != '=' && line[j] != ':') {
			continue
		}
		if v, ok := valueAt(line, j+1); ok {
			return v, true
		}
	}
	return nil, false
}
