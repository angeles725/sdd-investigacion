package corrections

import (
	"math/rand"
	"strings"
	"testing"
)

// The regexps the byte-level helpers of scanfast.go replace: the reference the helpers are pinned against.
var (
	refQuoteStrip = posix(`^[ \t]*(>[ \t]*)+`)
	refBlank      = posix(`^[ \t]*$`)
	refListHead   = posix(`^[ \t]*([-*+]|[0-9]+[.)])[ \t]`)
	refHeading    = posix(`^[ \t]*#`)
	refTableRow   = posix(`^[ \t]*\|`)
	refVerb       = posix(`(^|` + nonWord + `)(corrects|corrig[a-z]*)`)
	refSe         = posix(`(^|` + nonWord + `)se[ \t]+$`)
	refNegPre     = posix(`(^|` + nonWord + `)(no|nunca|never|tampoco)[ \t]+$`)
)

// pieces are the fragments (no newline: the POSIX regexps treat it as a line boundary, and the extractor never sees one inside a line or unit) the generated inputs are glued from: every byte class and word the helpers branch on.
var pieces = []string{
	" ", "\t", "  ", ">", "> ", "-", "*", "+", "#", "|", "1", "12", ".", ")", "(", "a", "x", "_", "é", "\xff", "\x00", ":",
	"se", "no", "nunca", "never", "tampoco", "corr", "corrects", "corrige", "corrigendum", "corrigi", "correct", "Corrects",
	"B12", "[Block 3]", ",", ";", "ó",
}

func gen(r *rand.Rand) string {
	var b strings.Builder
	for n := r.Intn(8); n > 0; n-- {
		b.WriteString(pieces[r.Intn(len(pieces))])
	}
	return b.String()
}

func TestScanFastEquivalentToRegexps(t *testing.T) {
	r := rand.New(rand.NewSource(2635))
	for i := 0; i < 200000; i++ {
		s := gen(r)
		wantQ := -1
		if loc := refQuoteStrip.FindStringIndex(s); loc != nil {
			wantQ = loc[1]
		}
		if got := quoteStripEnd(s); got != wantQ {
			t.Fatalf("quoteStripEnd(%q) = %d, regexp %d", s, got, wantQ)
		}
		if got, want := isBlankLine(s), refBlank.MatchString(s); got != want {
			t.Fatalf("isBlankLine(%q) = %v, regexp %v", s, got, want)
		}
		want := refListHead.MatchString(s) || refHeading.MatchString(s) || refTableRow.MatchString(s)
		if got := startsBlock(s); got != want {
			t.Fatalf("startsBlock(%q) = %v, regexps %v", s, got, want)
		}
		ws, wl := match(refVerb, s)
		if gs, gl := matchVerb(s); gs != ws || gl != wl {
			t.Fatalf("matchVerb(%q) = (%d,%d), regexp (%d,%d)", s, gs, gl, ws, wl)
		}
		if got, want := endsWord(s, "se"), refSe.MatchString(s); got != want {
			t.Fatalf("endsWord(%q, se) = %v, regexp %v", s, got, want)
		}
		if got, want := endsWord(s, "no", "nunca", "never", "tampoco"), refNegPre.MatchString(s); got != want {
			t.Fatalf("endsWord(%q, neg) = %v, regexp %v", s, got, want)
		}
	}
}
