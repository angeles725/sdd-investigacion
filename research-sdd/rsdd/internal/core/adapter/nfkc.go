package adapter

import "strings"

// nfkc is the part of unicodedata.normalize("NFKC", s) the path checks depend on. The Go standard
// library has no normalizer and the module takes no dependencies, so only the code points whose NFKC
// form contains printable ASCII are folded (nfkc_tables.go); everything else is returned as is.
//
// That is exact for what manifest.go asks of the result: whether it contains "..", a separator, a
// backslash or a URI scheme. Composition and reordering never create an ASCII character and can only
// consume a letter, which ends a scheme either way. Non-ASCII text is therefore NOT normalised, so
// do not use this function for anything else.
func nfkc(s string) string {
	var b strings.Builder
	for _, r := range s {
		if t, ok := foldRune(r); ok {
			b.WriteString(t)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func foldRune(r rune) (string, bool) {
	if t, ok := nfkcSingles[r]; ok {
		return t, true
	}
	for _, run := range nfkcRuns {
		if r >= run.lo && r <= run.hi {
			return string(run.dst + r - run.lo), true
		}
	}
	return "", false
}
