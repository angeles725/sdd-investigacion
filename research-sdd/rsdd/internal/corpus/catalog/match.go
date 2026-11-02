package catalog

import (
	"regexp"
	"strings"
	"unicode"
)

// pySpaceClass is Python's str.isspace set as a regexp class, what its Unicode-aware `\s` is.
const pySpaceClass = `[\t\n\v\f\r \x1c-\x1f\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`

// RE2 prefers the leftmost, Perl-like alternative, so the submatches equal those of Python's backtracking engine.
// The two expressions are the Python BLOCK_RE and TITLE_RE with `\d` as Nd, `\w` as L, N and `_`, and `\s` as {S}.
var (
	blockRE = regexp.MustCompile(`^(.+)-(?:block|bloque)(\p{Nd}+)(?:-[\p{L}\p{N}_-]+)?\.md$`)
	titleRE = regexp.MustCompile(strings.ReplaceAll(`^#{S}*(?:Block|Bloque){S}*\p{Nd}+{S}*[—-]{S}*(.+?){S}*$`, "{S}", pySpaceClass))
)

// matchBlock splits a file name into its prefix and normalized block number.
func matchBlock(name string) (prefix, num string, ok bool) {
	m := blockRE.FindStringSubmatch(name)
	if m == nil {
		return "", "", false
	}
	num, ok = decimal(m[2])
	if !ok {
		return "", "", false
	}
	return m[1], num, true
}

// decimal renders a run of Nd characters as an ASCII decimal without leading zeros ("0" for zero). ok is false when
// a character is not an Nd digit, which the block pattern never lets through.
func decimal(digits string) (string, bool) {
	var b []byte
	for _, r := range digits {
		v := digitValue(r)
		if v < 0 {
			return "", false
		}
		b = append(b, byte('0'+v))
	}
	for len(b) > 1 && b[0] == '0' {
		b = b[1:]
	}
	return string(b), true
}

// digitValue is the decimal value of an Nd character, or -1 for any other rune. Every Nd range of the Unicode tables
// is a whole number of runs of ten digits that start at zero, so the offset from the range start modulo ten is the
// value.
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
	return -1
}

// lessNum orders two normalized decimals numerically: a shorter one is smaller, equal lengths compare as text.
func lessNum(a, b string) bool {
	return len(a) < len(b) || (len(a) == len(b) && a < b)
}

// pySpaceTable is the same set as pySpaceClass, for strings.TrimFunc.
var pySpaceTable = &unicode.RangeTable{
	R16: []unicode.Range16{
		{Lo: 0x09, Hi: 0x0d, Stride: 1}, {Lo: 0x1c, Hi: 0x20, Stride: 1}, {Lo: 0x85, Hi: 0x85, Stride: 1},
		{Lo: 0xa0, Hi: 0xa0, Stride: 1}, {Lo: 0x1680, Hi: 0x1680, Stride: 1}, {Lo: 0x2000, Hi: 0x200a, Stride: 1},
		{Lo: 0x2028, Hi: 0x2029, Stride: 1}, {Lo: 0x202f, Hi: 0x202f, Stride: 1}, {Lo: 0x205f, Hi: 0x205f, Stride: 1},
		{Lo: 0x3000, Hi: 0x3000, Stride: 1},
	},
}

// isPySpace reports whether r is in Python's str.isspace set.
func isPySpace(r rune) bool { return unicode.Is(pySpaceTable, r) }
