package grammar

import (
	"reflect"
	"strings"
	"testing"
)

func TestAltEntryRows(t *testing.T) {
	long := strings.Repeat("ab ", 33) + "é tail" // the 100-byte cut lands inside é
	src := "## Proposed kit deltas\n" +
		"1. **Title one.** prose follows\n   PROPOSED lib/x.sh: change\n" +
		"2) Plain sentence here. Next one\n   indented keeps the item\n\nPROPOSED late: too late, item flushed\n" +
		"3. e.g. something. Then More\n" +
		"4. " + long + "\n" +
		"### Considered and rejected\n5. not an item\n" +
		"### Proposals (later)\n6. **unclosed bold title\n" +
		"## Delta R2 — MED — fix it\n### ignored inside h2d\n7. ignored\n" +
		"## Delta ID — not an id\n## Delta W3 — plain\n"
	d := Parse("r.md", src)
	want := []Row{
		{ID: "1", Change: "Title one", Target: "lib/x.sh", Evidence: "prose follows"},
		{ID: "2", Change: "Plain sentence here", Evidence: "Next one"},
		{ID: "3", Change: "e.g. something", Evidence: "Then More"},
		{ID: "4", Change: strings.TrimRight(long[:99], " "), Evidence: long[99:]},
		{ID: "6", Change: "unclosed bold title"},
		{ID: "R2", Change: "fix it", Priority: "MEDIUM"},
		{ID: "W3", Change: "plain"},
	}
	if got := AltEntryRows(d); !reflect.DeepEqual(got, want) {
		t.Errorf("AltEntryRows:\n got %q\nwant %q", got, want)
	}
	heads := []string{"## Proposed kit deltas", "### Proposals (later)", "## Delta R2 — MED — fix it", "## Delta W3 — plain"}
	if got := AltHeads(d); !reflect.DeepEqual(got, heads) {
		t.Errorf("AltHeads = %q, want %q", got, heads)
	}
}

func TestAltHeadsAreUnique(t *testing.T) {
	d := Parse("r.md", "### Proposals\n1. a\n### Proposals\n1. b\n")
	if got := AltHeads(d); !reflect.DeepEqual(got, []string{"### Proposals"}) {
		t.Errorf("AltHeads = %q", got)
	}
}

func TestSentenceEnd(t *testing.T) {
	for s, want := range map[string]int{
		"One. Two": 3, "one. two": -1, "e.g. x. Y": -1, "A. B": -1, "x cf. Yes. Z": 9, "end.": -1, "ab.  B": 2, "Vs. X": -1,
	} {
		if got := sentenceEnd(s); got != want {
			t.Errorf("sentenceEnd(%q) = %d, want %d", s, got, want)
		}
	}
}

func TestCutAt(t *testing.T) {
	for _, c := range []struct {
		s    string
		n    int
		want int
	}{{"abc", 5, 3}, {"abcdef", 3, 3}, {"ab\xc3\xa9cd", 3, 2}, {"\xc3\xa9", 1, 1}, {"\x80\x80\x80", 2, 2}} {
		if got := cutAt(c.s, c.n); got != c.want {
			t.Errorf("cutAt(%q, %d) = %d, want %d", c.s, c.n, got, c.want)
		}
	}
}
