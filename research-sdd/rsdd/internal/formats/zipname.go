package formats

import (
	"sort"
	"unicode/utf8"
)

// This file reproduces the three text operations the legacy ZIP readers took from Python's standard
// library: bytes.decode("utf-8", errors="replace"), bytes.decode("cp437") and unicodedata.normalize("NFC").
// Go's string conversion replaces every invalid byte, Python replaces each maximal invalid subpart once, so
// the entry names (and the canonical JSON built from them) would differ without these.

type zipDecomp struct{ cp, a, b rune }
type zipComposite struct{ a, b, cp rune }
type zipCCCRange struct {
	lo, hi rune
	class  uint8
}

// Hangul syllable constants (Unicode section 3.12).
const (
	hangulSBase  = 0xAC00
	hangulLBase  = 0x1100
	hangulVBase  = 0x1161
	hangulTBase  = 0x11A7
	hangulLCount = 19
	hangulVCount = 21
	hangulTCount = 28
	hangulNCount = hangulVCount * hangulTCount
	hangulSCount = hangulLCount * hangulNCount
)

// zipDecodeUTF8Replace is raw.decode("utf-8", errors="replace"): every maximal invalid subpart becomes one
// U+FFFD.
func zipDecodeUTF8Replace(raw []byte) string {
	if utf8.Valid(raw) {
		return string(raw)
	}
	out := make([]rune, 0, len(raw))
	for i := 0; i < len(raw); {
		r, n := utf8.DecodeRune(raw[i:])
		if r != utf8.RuneError || n > 1 {
			out = append(out, r)
			i += n
			continue
		}
		out = append(out, utf8.RuneError)
		i += invalidPrefixLen(raw[i:])
	}
	return string(out)
}

// invalidPrefixLen is the length of the maximal prefix of b (b[0] starts an invalid sequence) that is the
// beginning of some well-formed UTF-8 sequence: one byte for a stray or impossible lead byte, more for a
// truncated or overlong-looking sequence.
func invalidPrefixLen(b []byte) int {
	lo, hi := byte(0x80), byte(0xBF)
	need := 0
	switch c := b[0]; {
	case c >= 0xC2 && c <= 0xDF:
		need = 1
	case c == 0xE0:
		need, lo = 2, 0xA0
	case c >= 0xE1 && c <= 0xEC, c == 0xEE, c == 0xEF:
		need = 2
	case c == 0xED:
		need, hi = 2, 0x9F
	case c == 0xF0:
		need, lo = 3, 0x90
	case c >= 0xF1 && c <= 0xF3:
		need = 3
	case c == 0xF4:
		need, hi = 3, 0x8F
	default:
		return 1
	}
	n := 1
	for ; n <= need && n < len(b); n++ {
		if b[n] < lo || b[n] > hi {
			break
		}
		lo, hi = 0x80, 0xBF
	}
	return n
}

// zipDecodeCP437 is raw.decode("cp437").
func zipDecodeCP437(raw []byte) string {
	out := make([]rune, len(raw))
	for i, b := range raw {
		if b < 0x80 {
			out[i] = rune(b)
		} else {
			out[i] = zipCP437[b-0x80]
		}
	}
	return string(out)
}

// zipNFC is unicodedata.normalize("NFC", s) for a valid UTF-8 string, from tables generated out of Python's
// own unicodedata (see zipUnicodeVersion).
func zipNFC(s string) string {
	runes := []rune(s)
	dec := make([]rune, 0, len(runes))
	for _, r := range runes {
		dec = zipDecompose(dec, r)
	}
	zipReorder(dec)
	return string(zipComposeRunes(dec))
}

func zipDecompose(dst []rune, r rune) []rune {
	if r >= hangulSBase && r < hangulSBase+hangulSCount {
		s := r - hangulSBase
		dst = append(dst, hangulLBase+s/hangulNCount, hangulVBase+(s%hangulNCount)/hangulTCount)
		if t := s % hangulTCount; t != 0 {
			dst = append(dst, hangulTBase+t)
		}
		return dst
	}
	i := sort.Search(len(zipCanonDecomp), func(i int) bool { return zipCanonDecomp[i].cp >= r })
	if i == len(zipCanonDecomp) || zipCanonDecomp[i].cp != r {
		return append(dst, r)
	}
	d := zipCanonDecomp[i]
	dst = zipDecompose(dst, d.a)
	if d.b != 0 {
		dst = zipDecompose(dst, d.b)
	}
	return dst
}

func zipCCCOf(r rune) uint8 {
	i := sort.Search(len(zipCCC), func(i int) bool { return zipCCC[i].hi >= r })
	if i < len(zipCCC) && zipCCC[i].lo <= r {
		return zipCCC[i].class
	}
	return 0
}

// zipReorder is the canonical ordering algorithm: a stable sort of every run of non-starters by class.
func zipReorder(rs []rune) {
	for i := 0; i < len(rs); {
		if zipCCCOf(rs[i]) == 0 {
			i++
			continue
		}
		j := i
		for j < len(rs) && zipCCCOf(rs[j]) != 0 {
			j++
		}
		run := rs[i:j]
		sort.SliceStable(run, func(a, b int) bool { return zipCCCOf(run[a]) < zipCCCOf(run[b]) })
		i = j
	}
}

func zipPairCompose(a, b rune) (rune, bool) {
	if a >= hangulLBase && a < hangulLBase+hangulLCount && b >= hangulVBase && b < hangulVBase+hangulVCount {
		return hangulSBase + ((a-hangulLBase)*hangulVCount+(b-hangulVBase))*hangulTCount, true
	}
	if a >= hangulSBase && a < hangulSBase+hangulSCount && (a-hangulSBase)%hangulTCount == 0 &&
		b > hangulTBase && b < hangulTBase+hangulTCount {
		return a + (b - hangulTBase), true
	}
	i := sort.Search(len(zipCompose), func(i int) bool {
		c := zipCompose[i]
		return c.a > a || (c.a == a && c.b >= b)
	})
	if i < len(zipCompose) && zipCompose[i].a == a && zipCompose[i].b == b {
		return zipCompose[i].cp, true
	}
	return 0, false
}

// zipComposeRunes is the canonical composition algorithm over a canonically ordered, fully decomposed text.
func zipComposeRunes(rs []rune) []rune {
	if len(rs) == 0 {
		return rs
	}
	out := make([]rune, 0, len(rs))
	out = append(out, rs[0])
	starter := 0
	last := int(zipCCCOf(rs[0]))
	if last != 0 {
		last = 256
	}
	for _, r := range rs[1:] {
		class := int(zipCCCOf(r))
		if c, ok := zipPairCompose(out[starter], r); ok && (last < class || last == 0) {
			out[starter] = c
			continue
		}
		if class == 0 {
			starter = len(out)
		}
		last = class
		out = append(out, r)
	}
	return out
}
