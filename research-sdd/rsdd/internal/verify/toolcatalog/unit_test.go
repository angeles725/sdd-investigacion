package toolcatalog

import (
	"regexp"
	"strings"
	"testing"
	"unicode"
)

var (
	cLoc = locale{}
	uLoc = locale{utf8: true}
)

func TestCutBytes(t *testing.T) {
	t.Parallel()
	cases := []struct {
		in   string
		n    int
		want string
	}{
		{"abc", 3, "abc"}, {"abcd", 3, "abc"}, {"ab", 3, "ab"}, {"", 3, ""},
		{"a\xbf", 2, "a\xbf"},                         // a stray continuation byte is not a lead
		{"a\xc0", 2, "a"},                             // lowest 2-byte lead, alone
		{"a\xdf", 2, "a"},                             // highest 2-byte lead, alone
		{"a\xe0", 2, "a"},                             // 3-byte leads
		{"a\xef", 2, "a"},                             //
		{"a\xe0\x80", 3, "a"},                         // one continuation of two
		{"a\xe0\xbf", 3, "a"},                         //
		{"a\xe0\x7f", 3, "a\xe0\x7f"},                 // 0x7f is no continuation
		{"a\xe0\xc0", 3, "a\xe0"},                     // 0xc0 is no continuation, itself an incomplete lead
		{"a\xf0", 2, "a"},                             // 4-byte leads
		{"a\xf7", 2, "a"},                             //
		{"a\xf8", 2, "a\xf8"},                         // 0xf8 is no lead
		{"a\xf0\x80\xbf", 4, "a"},                     // two continuations of three
		{"a\xf0\x80\xbf\x80", 5, "a\xf0\x80\xbf\x80"}, // complete
		{"a\xc3\xa9", 3, "a\xc3\xa9"},                 // é complete
		{"a\xe2\x82\xac", 4, "a\xe2\x82\xac"},         // € complete
		{"a\xe2\x82\xac", 3, "a"},                     // € cut after 2 bytes
		{"a\xe2\x82\xac", 2, "a"},                     // cut after 1
		{"\xe0\x80\x80\x80", 4, "\xe0\x80\x80\x80"},   // lead with more continuations than it admits stays
		{"a\xe0\x80\x80x", 5, "a\xe0\x80\x80x"},       // text after it
	}
	for _, c := range cases {
		if got := cutBytes(c.in, c.n); got != c.want {
			t.Errorf("cutBytes(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}

func TestSpaceClass(t *testing.T) {
	t.Parallel()
	for _, r := range []rune{'\t', '\n', '\v', '\f', '\r', ' '} {
		if !cLoc.isSpace(r) || !uLoc.isSpace(r) {
			t.Errorf("%U should be a space in both locales", r)
		}
	}
	for _, r := range []rune{0x08, 0x0e, 0x1f, '!', 0x7f, 0x85, 0xa0} {
		if cLoc.isSpace(r) || uLoc.isSpace(r) {
			t.Errorf("%U should not be a space", r)
		}
	}
	for _, r := range []rune{0x1680, 0x2000, 0x2003, 0x2006, 0x2008, 0x200a, 0x2028, 0x2029, 0x205f, 0x3000} {
		if cLoc.isSpace(r) || !uLoc.isSpace(r) {
			t.Errorf("%U: a space only in UTF-8", r)
		}
	}
	for _, r := range []rune{0x167f, 0x1681, 0x1fff, 0x2007, 0x200b, 0x2027, 0x202a, 0x202f, 0x205e, 0x2060, 0x2fff, 0x3001} {
		if uLoc.isSpace(r) {
			t.Errorf("%U should not be a space", r)
		}
	}
}

func TestWordClass(t *testing.T) {
	t.Parallel()
	for _, r := range []rune{'0', '5', '9', 'a', 'm', 'z', 'A', 'M', 'Z', '_'} {
		if !cLoc.isWord(r) || !uLoc.isWord(r) {
			t.Errorf("%q should be a word constituent", r)
		}
	}
	for _, r := range []rune{'/', ':', '@', '[', '`', '{', '-', '.', ' ', '\''} {
		if cLoc.isWord(r) || uLoc.isWord(r) {
			t.Errorf("%q should not be a word constituent", r)
		}
	}
	if cLoc.isWord('é') || !uLoc.isWord('é') || !uLoc.isWord('٣') || uLoc.isWord('́') || uLoc.isWord('—') {
		t.Error("non-ASCII word constituents are Unicode letters and digits, in UTF-8 only")
	}
	if uLoc.isWord(invalidBase+'a') || uLoc.isWord(invalidBase) {
		t.Error("an invalid byte is no word constituent, whatever byte it is")
	}
}

func TestSameLetter(t *testing.T) {
	t.Parallel()
	yes := [][2]rune{{'a', 'A'}, {'A', 'a'}, {'z', 'Z'}, {'Z', 'z'}, {'m', 'M'}, {'q', 'q'}}
	no := [][2]rune{{'`', '@'}, {'@', '`'}, {'{', '['}, {'[', '{'}, {'a', 'b'}, {'a', 'a' + 1}, {'A', 'B'}, {'é', 'É'}}
	for _, p := range yes {
		if !cLoc.sameLetter(p[0], p[1]) || !uLoc.sameLetter(p[0], p[1]) {
			t.Errorf("%q and %q should match", p[0], p[1])
		}
	}
	for _, p := range no {
		if p[0] == 'é' {
			continue
		}
		if cLoc.sameLetter(p[0], p[1]) || uLoc.sameLetter(p[0], p[1]) {
			t.Errorf("%q and %q should not match", p[0], p[1])
		}
	}
	if cLoc.sameLetter('é', 'É') || !uLoc.sameLetter('é', 'É') || !uLoc.sameLetter('É', 'é') {
		t.Error("é/É match in UTF-8 only")
	}
	// the variants of the pattern character only: the Kelvin sign is no k, but a pattern Kelvin sign matches k
	if uLoc.sameLetter('K', 'k') || !uLoc.sameLetter('k', 'K') {
		t.Error("the fold goes from the pattern character")
	}
	for _, p := range [][2]rune{{'ς', 'Σ'}, {'σ', 'ς'}, {'µ', 'Μ'}, {'ı', 'I'}} {
		if !uLoc.sameLetter(p[0], p[1]) {
			t.Errorf("%q should match pattern %q (lonesome lowercase)", p[0], p[1])
		}
	}
	if uLoc.sameLetter('ς', 'a') || uLoc.sameLetter(invalidBase+0xff, invalidBase+0xfe) || !uLoc.sameLetter(invalidBase+0xff, invalidBase+0xff) {
		t.Error("invalid bytes match only themselves")
	}
}

func TestDecoding(t *testing.T) {
	t.Parallel()
	if r, n := uLoc.next("\xff", 0); r != invalidBase+0xff || n != 1 || r <= unicode.MaxRune {
		t.Errorf("next(invalid) = %U, %d", r, n)
	}
	if r, n := uLoc.next("\xfe", 0); r != invalidBase+0xfe || n != 1 {
		t.Errorf("next(invalid) = %U, %d", r, n)
	}
	if r, n := uLoc.next("�", 0); r != unicode.ReplacementChar || n != 3 {
		t.Errorf("a real U+FFFD stays itself: %U, %d", r, n)
	}
	if r, n := uLoc.last("a\xff"); r != invalidBase+0xff || n != 1 {
		t.Errorf("last(invalid) = %U, %d", r, n)
	}
	if r, n := uLoc.last("a�"); r != unicode.ReplacementChar || n != 3 {
		t.Errorf("a real U+FFFD stays itself: %U, %d", r, n)
	}
	if r, n := cLoc.next("é", 0); r != 0xc3 || n != 1 {
		t.Errorf("the C locale reads bytes: %U, %d", r, n)
	}
	if r, n := cLoc.last("é"); r != 0xa9 || n != 1 {
		t.Errorf("the C locale reads bytes: %U, %d", r, n)
	}
}

func TestTrim(t *testing.T) {
	t.Parallel()
	if got := uLoc.trim("  a b 　\t"); got != "a b" {
		t.Errorf("got %q", got)
	}
	if got := cLoc.trim("  a"); got != "  a" {
		t.Errorf("the C locale trims ASCII space only: %q", got)
	}
	if uLoc.trim(" \t ") != "" || uLoc.trim("") != "" || uLoc.trim("x") != "x" {
		t.Error("edge cases")
	}
}

func TestRowShapes(t *testing.T) {
	t.Parallel()
	sep := map[string]bool{"|-|": true, "| : |": true, "|---|---|": true, "|  --  |": true, "||": false, "| |": false, "|-": false, "| a-- |": false, "|-x|": false, "| - |": true}
	for row, want := range sep {
		if got := uLoc.isSeparatorRow(row); got != want {
			t.Errorf("isSeparatorRow(%q) = %v", row, got)
		}
	}
	hdr := map[string]bool{"|tool|": true, "| TOOL |": true, "|Tool": false, "|too|": false, "|tool": false, "|tools|": false, "|  tool  | x |": true, "|": false, "|tOoL |": true, "| tool|": true}
	for row, want := range hdr {
		if got := uLoc.isHeaderRow(row); got != want {
			t.Errorf("isHeaderRow(%q) = %v", row, got)
		}
	}
	if got := cell2("|a|b"); got != "a" {
		t.Errorf("cell2 = %q", got)
	}
	if cell2("|only") != "only" || cell2("|") != "" {
		t.Error("cell2 without a closing pipe")
	}
	if got := awkField2("## \tx (y)"); got != "x" {
		t.Errorf("awkField2 = %q", got)
	}
}

func TestToolNamesOrder(t *testing.T) {
	t.Parallel()
	got := uLoc.toolNames("## h (x)\n| b | x |\n| a | x |\n| b | y |\n## b (z)\n## c (z)")
	if strings.Join(got, ",") != "b,a,h,c" {
		t.Errorf("got %v", got)
	}
}

func TestHasWordEdges(t *testing.T) {
	t.Parallel()
	for _, l := range []locale{cLoc, uLoc} {
		if l.hasWord("ab", "abc") || l.hasWord("xcf", "cfr") || !l.hasWord("a cfr", "cfr") || l.hasWord("", "a") {
			t.Errorf("%+v: a pattern that runs past the line never matches", l)
		}
		if !l.hasWord("cfr", "cfr") || l.hasWord("cfrx", "cfr") || l.hasWord("xcfr", "cfr") {
			t.Errorf("%+v: line edges", l)
		}
	}
	if uLoc.hasWord("a", "�") {
		t.Error("a pattern past the end must not match a replacement character")
	}
}

func TestNumbersAndSummaryParsing(t *testing.T) {
	t.Parallel()
	text := "Summary: 12 distinct · 3 not cataloged 45 not cataloged\nSummary: 7"
	if got := strings.Join(numbers(text, reLogged), ","); got != "12,7" {
		t.Errorf("logged = %q", got)
	}
	if got := strings.Join(numbers(text, reNotCataloged), ","); got != "3,45" {
		t.Errorf("not cataloged = %q", got)
	}
	if numbers("", regexp.MustCompile(`(x)`)) != nil {
		t.Error("no text, no numbers")
	}
	var ctx string
	ctx, _ = hookContext("Summary: 3 distinct · 0 not cataloged 2 not cataloged", 0, false)
	if !strings.HasPrefix(ctx, hookDriftHeader) {
		t.Errorf("a later non-zero count is drift: %q", ctx)
	}
}
