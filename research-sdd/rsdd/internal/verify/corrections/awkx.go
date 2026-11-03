package corrections

import (
	"regexp"
	"strings"
)

// Helpers that keep the extractor a line-by-line translation of the awk program of verify-corrections.sh, which
// ran under LC_ALL=C: strings are BYTE strings, indexes are 1-based, a regular expression is POSIX
// leftmost-longest. The awk globals RSTART/RLENGTH are returned by match.

// asciiLower is awk's tolower under LC_ALL=C: ASCII only, so byte lengths and positions never change.
func asciiLower(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

// substr is awk's substr(s, i, n): i is 1-based; n < 0 means "to the end". The window is clamped to the string.
func substr(s string, i, n int) string {
	end := len(s) + 1
	if n >= 0 {
		end = i + n
	}
	// Clamp the window to [1, len+1] and make it non-negative: an empty window slices to "" (s[k:k]), so the
	// "end <= i" early return of the awk text is the same thing as end = max(end, i).
	i = min(max(i, 1), len(s)+1)
	end = max(min(end, len(s)+1), i)
	return s[i-1 : end-1]
}

// from is substr(s, i): the suffix from the 1-based position i.
func from(s string, i int) string { return substr(s, i, -1) }

// match is awk's match(s, re): the 1-based start and the length of the leftmost-longest match, or (0, -1).
func match(re *regexp.Regexp, s string) (rstart, rlength int) {
	loc := re.FindStringIndex(s)
	if loc == nil {
		return 0, -1
	}
	return loc[0] + 1, loc[1] - loc[0]
}

// posix compiles a POSIX ERE (leftmost-longest, like awk's matcher); a bad pattern is a programming error.
func posix(p string) *regexp.Regexp { return regexp.MustCompilePOSIX(p) }

// digitsOf is gsub(/[^0-9]/, "", s).
func digitsOf(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] >= '0' && s[i] <= '9' {
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// isWordByte is the awk class [a-z0-9_\200-\377] (a letter, digit, underscore or any byte of a multi-byte
// character), the "word text" of the program's boundary rules.
func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c >= 0x80
}

// wordAt reports whether the 1-based position i of s holds a word byte (false past the end).
func wordAt(s string, i int) bool { return i >= 1 && i <= len(s) && isWordByte(s[i-1]) }

// nonWord is the awk class [^a-z0-9_\200-\377] restricted to the bytes it can match: the ASCII non-word bytes.
const nonWord = `[\x00-\x2f\x3a-\x40\x5b-\x5e\x60\x7b-\x7f]`
