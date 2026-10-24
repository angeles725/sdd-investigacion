package grammar

import (
	"reflect"
	"strings"
	"testing"
)

// Boundary cases that pin each comparison of the byte helpers and the alt-entry parser on its exact edge (found
// by gremlins: these mutants survived the behaviour tests).

func TestByteClassHelpers(t *testing.T) {
	for c := 0; c < 256; c++ {
		b := byte(c)
		if want := strings.IndexByte(" \t\n\v\f\r", b) >= 0; isSpace(b) != want {
			t.Errorf("isSpace(%#x) = %v", c, !want)
		}
		if want := ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z'); isASCIIAlpha(b) != want {
			t.Errorf("isASCIIAlpha(%#x) = %v", c, !want)
		}
	}
	if got := asciiLetters("az@[`{AZ\xc3\xa9"); got != "azAZ" {
		t.Errorf("asciiLetters = %q", got)
	}
	if got := upper("az`{AZ"); got != "AZ`{AZ" {
		t.Errorf("upper = %q", got)
	}
	if firstField(" a") != "" || firstField("a\tb") != "a" || firstField("ab") != "ab" {
		t.Errorf("firstField: %q %q %q", firstField(" a"), firstField("a\tb"), firstField("ab"))
	}
	if got := splitCells(" a| b |c "); !reflect.DeepEqual(got, []string{" a", "b", "c "}) {
		t.Errorf("splitCells trailing pipe-less = %q", got)
	}
	if got := splitCells("| a | b  "); !reflect.DeepEqual(got, []string{"a", "b  "}) {
		t.Errorf("splitCells keeps the last cell's blanks without a trailing pipe = %q", got)
	}
}

func TestSentenceEndEdges(t *testing.T) {
	for s, want := range map[string]int{
		"One. a": -1, "One. z": -1, "One. `": 3, "ab. {": 2, "Title. ": 5, ". Next": 0, " a. Bx": -1,
	} {
		if got := sentenceEnd(s); got != want {
			t.Errorf("sentenceEnd(%q) = %d, want %d", s, got, want)
		}
	}
	if got := cutAt("abc", 3); got != 3 {
		t.Errorf("cutAt at the exact length = %d", got)
	}
}

func TestAltItemEdges(t *testing.T) {
	colon := func(at int) string { return "   PROPOSED " + strings.Repeat("t", at) + ": x\n" }
	src := "## Proposed kit deltas\n" +
		"1. . Next\n" + // a sentence ending at 0 leaves an empty title: no item
		"2. ** a. Bx**\n" + // the bold span keeps its leading blank: ` a` is no single-letter word
		"3. **T. **\n" +
		"4. A\n" + colon(119) +
		"5. B\n" + colon(120) +
		"6. **C** " + strings.Repeat("e", 300) + "\n"
	want := []Row{
		{ID: "2", Change: "a. Bx"},
		{ID: "3", Change: "T"},
		{ID: "4", Change: "A", Target: strings.Repeat("t", 119)},
		{ID: "5", Change: "B"},
		{ID: "6", Change: "C", Evidence: strings.Repeat("e", 300)},
	}
	if got := AltEntryRows(Parse("r.md", src)); !reflect.DeepEqual(got, want) {
		t.Errorf("AltEntryRows:\n got %q\nwant %q", got, want)
	}
}

func TestHonestyEmptyCanonicalWithoutVerdict(t *testing.T) {
	if HasHonesty(Parse("r.md", "## Proposed kit deltas\n\n")) {
		t.Error("an empty canonical section with no Honest verdict is not honesty")
	}
}

func TestRowTitlesSpacedDebrisKeepsFallback(t *testing.T) {
	// `- -` loses its blanks and is separator debris: no table row, so the entry form answers.
	d := Parse("r.md", "## Proposed kit deltas\n| - - | x |\n### D1 — entry\n")
	if got := RowTitles(d); !reflect.DeepEqual(got, []TitleRow{{"D1", "entry"}}) {
		t.Errorf("RowTitles = %q", got)
	}
}
