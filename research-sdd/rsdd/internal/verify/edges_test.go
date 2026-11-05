package verify

import (
	"strings"
	"testing"
)

// The byte-class edges of the small pure helpers (kit issue #2592: each was a lived mutant of the first teeth
// run on this package). Every byte is checked against an oracle written out as an alphabet, so a shifted
// boundary ('0' vs '1', 'Z' vs 'Y') is caught at the exact byte it moves.

const (
	alnumBytes   = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	literalBytes = alnumBytes + "_-"  // [A-Za-z0-9_-]
	keptBytes    = alnumBytes + "._-" // tr -cd '[:alnum:]._-' under LC_ALL=C
)

func TestLiteralPrefixAcceptsExactlyTheERELiteralBytes(t *testing.T) {
	t.Parallel()
	for b := 0; b < 256; b++ {
		s := string([]byte{byte(b)})
		if got, want := literalPrefix(s), strings.Contains(literalBytes, s); got != want {
			t.Errorf("literalPrefix(%q) = %v, want %v", s, got, want)
		}
		if literalPrefix("ok"+s+"ok") != strings.Contains(literalBytes, s) {
			t.Errorf("literalPrefix judges %q differently in the middle of a prefix", s)
		}
	}
	if !literalPrefix("") {
		t.Error("the empty prefix is literal (every line contains it)")
	}
}

func TestSanitisedKeepsExactlyAlnumDotUnderscoreDash(t *testing.T) {
	t.Parallel()
	for b := 0; b < 256; b++ {
		s := string([]byte{byte(b)})
		want := ""
		if strings.Contains(keptBytes, s) {
			want = s
		}
		if got := sanitised("<" + s + ">"); got != want {
			t.Errorf("sanitised(%q) = %q, want %q", "<"+s+">", got, want)
		}
	}
	if got := sanitised(strings.Repeat("a", 31)); got != strings.Repeat("a", 30) {
		t.Errorf("sanitised keeps %d characters, want 30", len(got))
	}
}

func TestThresholdAcceptsOneToSixDigits(t *testing.T) {
	t.Parallel()
	for _, c := range []struct {
		in string
		n  int
		ok bool
	}{
		{"", 0, false}, {"0", 0, true}, {"7", 7, true}, {"123456", 123456, true}, {"1234567", 0, false},
		{"000009", 9, true}, {"12a", 0, false}, {"-1", 0, false},
	} {
		if n, ok := threshold(c.in); n != c.n || ok != c.ok {
			t.Errorf("threshold(%q) = %d, %v; want %d, %v", c.in, n, ok, c.n, c.ok)
		}
	}
}

func TestRuneCutCountsRunesNotBytes(t *testing.T) {
	t.Parallel()
	for _, c := range []struct {
		in   string
		n    int
		want string
	}{
		{"", 3, ""}, {"abc", 3, "abc"}, {"abcd", 3, "abc"}, {"ééé", 2, "éé"}, {"ab", 0, ""},
		// invalid UTF-8 survives unless the string is cut: exactly n runes, and fewer, come back byte for byte
		{"a\xff", 2, "a\xff"}, {"a\xff", 5, "a\xff"}, {"a\xffbc", 2, "a\uFFFD"},
	} {
		if got := runeCut(c.in, c.n); got != c.want {
			t.Errorf("runeCut(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}

// driftBlock splits on the FIRST " kept-hand-edit=" and " drifted=", also when one starts the line.
func TestDriftBlockMarkersAtTheStartOfTheLine(t *testing.T) {
	t.Parallel()
	for _, c := range []struct {
		in   string
		want []string
	}{
		{" kept-hand-edit=x", []string{""}},
		{" drifted=a", []string{"", "  - a"}},
		{" drifted=a kept-hand-edit=k", []string{"", "  - a", "  kept-hand-edit: k"}},
		{"h drifted=", []string{"h"}},
	} {
		if got := driftBlock(c.in); strings.Join(got, "\n") != strings.Join(c.want, "\n") {
			t.Errorf("driftBlock(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestKeepTailEdges(t *testing.T) {
	t.Parallel()
	var bytesLocale awkChars // LC_ALL=C: lengths and cuts in bytes
	atMax := "a. " + strings.Repeat("b", compactInfoMax-3)
	if got := keepTail(atMax, bytesLocale); got != atMax {
		t.Errorf("a line of exactly compactInfoMax characters is kept whole, got %q", got)
	}
	over := atMax + "c"
	if got, want := keepTail(over, bytesLocale), bytesLocale.cut(over, compactHeadMax)+" "+over[3:]; got != want {
		t.Errorf("one character over compactInfoMax:\n got %q\nwant %q", got, want)
	}
	// the last ". " wins even when one sentence separator directly follows another
	stacked := strings.Repeat("h", compactInfoMax+10) + ". . tail"
	if got, want := keepTail(stacked, bytesLocale), bytesLocale.cut(stacked, compactHeadMax)+" tail"; got != want {
		t.Errorf("stacked separators:\n got %q\nwant %q", got, want)
	}
}

// utf8Trim treats 0x80-0xBF (and only those) as continuation bytes.
func TestUTF8TrimContinuationRangeEdges(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ in, out string }{
		{"abc\xe0\xbf", "abc"},                 // 0xBF is the last continuation byte: the sequence is incomplete
		{"abc\xe0\x80", "abc"},                 // 0x80 is the first
		{"abc\xe0\xc0x", "abc\xe0\xc0x"},       // 0xC0 starts a new sequence instead of continuing the one before it
		{"abc\xe0\xbf\xbf", "abc\xe0\xbf\xbf"}, // complete
	} {
		if got := utf8Trim(c.in); got != c.out {
			t.Errorf("utf8Trim(%q) = %q, want %q", c.in, got, c.out)
		}
	}
}
