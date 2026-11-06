package toolcatalog

import (
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

// locale is the character rules grep, awk and bash apply to the two inputs: in a UTF-8 locale a character is a rune
// and the classes are Unicode's (glibc's); in any other locale it is a byte and only ASCII has a class or a case.
type locale struct{ utf8 bool }

// localeOf is the effective locale: LC_ALL, else LC_CTYPE, else LANG.
func localeOf(env func(string) string) locale {
	loc := env("LC_ALL")
	if loc == "" {
		loc = env("LC_CTYPE")
	}
	if loc == "" {
		loc = env("LANG")
	}
	loc = strings.ToLower(loc)
	return locale{strings.Contains(loc, "utf-8") || strings.Contains(loc, "utf8")}
}

// invalidBase puts a byte that is not valid UTF-8 above Unicode, one distinct "character" per byte value, so two
// different bad bytes never compare equal and none is a letter, a digit or a space.
const invalidBase = 0x110000 // unicode.MaxRune + 1

// next is the character at byte offset i of s and its width in bytes.
func (l locale) next(s string, i int) (rune, int) {
	if !l.utf8 {
		return rune(s[i]), 1
	}
	r, n := utf8.DecodeRuneInString(s[i:])
	if r == utf8.RuneError && n == 1 {
		return invalidBase + rune(s[i]), 1
	}
	return r, n
}

// isSpace is `[[:space:]]`.
func (l locale) isSpace(r rune) bool {
	if r == ' ' || (r >= '\t' && r <= '\r') {
		return true
	}
	if !l.utf8 {
		return false
	}
	// glibc's space class: the Unicode spaces that are not no-break.
	return r == 0x1680 || (r >= 0x2000 && r <= 0x2006) || (r >= 0x2008 && r <= 0x200A) ||
		r == 0x2028 || r == 0x2029 || r == 0x205F || r == 0x3000
}

// isWord is a word constituent of grep -w: a letter, a digit or an underscore.
func (l locale) isWord(r rune) bool {
	if r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
		return true
	}
	return l.utf8 && (unicode.IsLetter(r) || unicode.IsDigit(r))
}

// sameLetter is whether the text character a matches the pattern character b ignoring case (grep -i): a is b, or one
// of the variants the pattern character's own upper and lower case give, so the Kelvin sign is not a "k" but a pattern
// "k" does match "K". In a non-UTF-8 locale only ASCII letters have a case.
func (l locale) sameLetter(a, b rune) bool {
	if a == b {
		return true
	}
	if !l.utf8 {
		return asciiLower(a) == asciiLower(b)
	}
	up := unicode.ToUpper(b)
	if a == up || a == unicode.ToLower(up) || a == unicode.ToLower(b) {
		return true
	}
	return slices.Contains(lonesomeLower[:], a) && unicode.ToUpper(a) == up
}

// asciiLower is r with A-Z lowercased.
func asciiLower(r rune) rune {
	if r >= 'A' && r <= 'Z' {
		return r + 'a' - 'A'
	}
	return r
}

// lonesomeLower are the lowercase letters whose uppercase does not lowercase back to them (gnulib's dfa.c table of
// them, which grep -i adds to the variants of a pattern character).
var lonesomeLower = [...]rune{0xB5, 0x131, 0x17F, 0x1C5, 0x1C8, 0x1CB, 0x1F2, 0x345, 0x3C2, 0x3D0, 0x3D1, 0x3D5, 0x3D6,
	0x3F0, 0x3F1, 0x3F2, 0x3F5, 0x1E9B, 0x1FBE}

// trim is s without the leading and trailing `[[:space:]]`.
func (l locale) trim(s string) string {
	start := 0
	for start < len(s) {
		r, n := l.next(s, start)
		if !l.isSpace(r) {
			break
		}
		start += n
	}
	end := len(s)
	for end > start {
		r, n := l.last(s[:end])
		if !l.isSpace(r) {
			break
		}
		end -= n
	}
	return s[start:end]
}

// last is the final character of s (s is not empty) and its width.
func (l locale) last(s string) (rune, int) {
	if !l.utf8 {
		return rune(s[len(s)-1]), 1
	}
	r, n := utf8.DecodeLastRuneInString(s)
	if r == utf8.RuneError && n == 1 {
		return invalidBase + rune(s[len(s)-1]), 1
	}
	return r, n
}
