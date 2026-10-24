package grammar

import (
	"reflect"
	"testing"
)

func TestTitleHasIdentity(t *testing.T) {
	for title, want := range map[string]bool{
		"HIGH": false, "Bugfix": false, "doc-fix": false, "documentation": false, "abcdefghijkl": true, "abcdefghijk": false,
		"ééééééééééé": false, "éééééééééééé": true, "\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4": true,
		"abcdefghij\xc3": false, "abcdefghi\x80\x80\x80": true, "high priority!": true, "": false,
	} {
		if got := TitleHasIdentity(title); got != want {
			t.Errorf("TitleHasIdentity(%q) = %v, want %v", title, got, want)
		}
	}
}

func TestIconvUTF8(t *testing.T) { // the acceptance set probed from glibc 2.39 iconv
	for s, want := range map[string]bool{
		"": true, "abc": true, "é": true, "\xf4\x90\x80\x80": true, "\xf7\xbf\xbf\xbf": true, "\xf8\x88\x80\x80\x80": true,
		"\xfd\xbf\xbf\xbf\xbf\xbf": true, "\xef\xbf\xbe": true, "\xed\xa0\x80": false, "\xed\xbf\xbf": false,
		"\xf0\x8f\xbf\xbf": false, "\xe0\x9f\xbf": false, "\xc1\xbf": false, "\xfe": false, "\xf8\x87\xbf\xbf\xbf": false,
		"\xfc\x83\xbf\xbf\xbf\xbf": false, "\xc3": false, "\x80": false, "\xc3a": false,
	} {
		if got := iconvUTF8(s); got != want {
			t.Errorf("iconvUTF8(%q) = %v, want %v", s, got, want)
		}
	}
}

func TestRowTitles(t *testing.T) {
	src := "## Proposed kit deltas\n" +
		"| ID | Target | Proposed change |\nprose between keeps the header\n|---|---|---|\n" +
		"| D1 | lib/x | **Bold title** and more |\n| D 2 | t | spaced id dropped |\n| D3 | t | a\\| b |\n" +
		"| x\\|y | t | escaped pipe in id |\n| SPKI-A | t | hyphen header-like id is skipped here |\n" +
		"| R7 | t | **unclosed |\n| B12 |\n|  D4  | t |  trimmed  \n" +
		"## Other\n| D9 | outside | x |\n"
	want := []TitleRow{
		{"D1", "Bold title"}, {"D3", "a| b"}, {"R7", "unclosed"}, {"B12", ""}, {"D4", "trimmed"},
	}
	if got := RowTitles(Parse("r.md", src)); !reflect.DeepEqual(got, want) {
		t.Errorf("RowTitles:\n got %q\nwant %q", got, want)
	}
	// no table row: the entry form answers, through the same id and bold rules
	entry := "## Proposed kit deltas\n### D1 — **Ent** tail\n### D.2 — dotted\n"
	if got := RowTitles(Parse("r.md", entry)); !reflect.DeepEqual(got, []TitleRow{{"D1", "Ent"}}) {
		t.Errorf("entry fallback = %q", got)
	}
	// a bare pipe row is still a table row: it blocks the entry fallback and yields nothing itself
	if got := RowTitles(Parse("r.md", "## Proposed kit deltas\n|\n### D1 — x\n")); len(got) != 0 {
		t.Errorf("bare pipe row = %q", got)
	}
	if got := (TitleRow{"D1", "t"}).Line(); got != "D1\x1ft\n" {
		t.Errorf("Line = %q", got)
	}
}
