package catalog

import (
	"regexp"
	"unicode"
)

// pySpace is Python's str.isspace set, the class its Unicode-aware `\s` and str.strip() use.
const pySpace = `\t\n\v\f\r \x1c-\x1f\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

// RE2 prefers the leftmost, Perl-like alternative, so the submatches equal those of Python's backtracking engine.
// The two expressions are the Python BLOCK_RE and TITLE_RE with `\d` as Nd, `\w` as L, N and `_`, and `\s` as pySpace.
var (
	blockRE = regexp.MustCompile(`^(.+)-(?:block|bloque)(\p{Nd}+)(?:-[\p{L}\p{N}_-]+)?\.md$`)
	titleRE = regexp.MustCompile(`^#[` + pySpace + `]*(?:Block|Bloque)[` + pySpace + `]*\p{Nd}+[` + pySpace + `]*[—-][` + pySpace + `]*(.+?)[` + pySpace + `]*$`)
)

// matchBlock splits a file name into its prefix and normalized block number.
func matchBlock(name string) (prefix, num string, ok bool) {
	m := blockRE.FindStringSubmatch(name)
	if m == nil {
		return "", "", false
	}
	return m[1], decimal(m[2]), true
}

// decimal renders a run of Nd characters as an ASCII decimal without leading zeros ("0" for zero).
func decimal(digits string) string {
	var b []byte
	for _, r := range digits {
		b = append(b, byte('0'+digitValue(r)))
	}
	for len(b) > 1 && b[0] == '0' {
		b = b[1:]
	}
	return string(b)
}

// digitValue is the decimal value of an Nd character. Every Nd range of the Unicode tables is a whole number of
// runs of ten digits that start at zero, so the offset from the range start modulo ten is the value.
func digitValue(r rune) int {
	for _, rg := range unicode.Nd.R16 {
		if r >= rune(rg.Lo) && r <= rune(rg.Hi) {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	for _, rg := range unicode.Nd.R32 {
		if r >= rune(rg.Lo) && r <= rune(rg.Hi) {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	return 0
}

// lessNum orders two normalized decimals numerically: a shorter one is smaller, equal lengths compare as text.
func lessNum(a, b string) bool {
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	return a < b
}

// isPySpace reports whether r is in Python's str.isspace set (the same set as pySpace).
func isPySpace(r rune) bool {
	switch {
	case r >= '\t' && r <= '\r', r >= 0x1c && r <= 0x20, r == 0x85, r == 0xa0, r == 0x1680,
		r >= 0x2000 && r <= 0x200a, r == 0x2028, r == 0x2029, r == 0x202f, r == 0x205f, r == 0x3000:
		return true
	}
	return false
}
