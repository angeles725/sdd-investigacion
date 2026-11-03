package reconcile

import (
	"reflect"
	"strings"
	"testing"
)

func TestIssueRowIDs(t *testing.T) {
	cases := []struct {
		name, bodies string
		prefixes     []string
		want         []string
	}{
		{"empty bodies", "", []string{"t/retros/r.md"}, nil},
		{"fixed string, not a regex", "Source retro: tXfoo/retros/r.md · 1\nSource retro: t.foo/retros/r.md · 2", []string{"t.foo/retros/r.md"}, []string{"2"}},
		{"prefixes in order, duplicates kept", "Source retro: b/retros/r.md · 2\nSource retro: a/retros/r.md · 1\nSource retro: a/retros/r.md · 1", []string{"a/retros/r.md", "b/retros/r.md"}, []string{"1", "1", "2"}},
		{"id after the last separator", "Source retro: a/retros/r.md · 1 · 7x", []string{"a/retros/r.md"}, []string{"7x"}},
		{"line without id", "Source retro: a/retros/r.md · ", []string{"a/retros/r.md"}, nil},
	}
	for _, c := range cases {
		if got := issueRowIDs(c.bodies, c.prefixes); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestTableIDs(t *testing.T) {
	const head = "## Proposed kit deltas\n\n| # | Change |\n|---|---|\n"
	src := head + "| 1 | a |\n| D 2 | b |\n| | blank id |\n\n| 3 | c |\n## Notes\n| 9 | d |"
	lines := strings.Split(src, "\n")
	if got, want := tableIDs(lines), []string{"1", "D 2", "3"}; !reflect.DeepEqual(got, want) {
		t.Errorf("tableIDs = %v, want %v (an empty id emits nothing, a blank line keeps the section, an H2 ends it)", got, want)
	}
}

// TestIDBytesAtTheRangeEdges pins each range edge of the id alphabet and the byte just outside it.
func TestIDBytesAtTheRangeEdges(t *testing.T) {
	for _, c := range []byte("azAZ09_-") {
		if !isIDByte(c) {
			t.Errorf("isIDByte(%q) = false, want true", c)
		}
	}
	for _, c := range []byte("`{@[/:. |") {
		if isIDByte(c) {
			t.Errorf("isIDByte(%q) = true, want false", c)
		}
	}
	if got := leadingID("aZ09_-z:rest"); got != "aZ09_-z" {
		t.Errorf("leadingID = %q", got)
	}
}

// TestLowerASCIIFoldsOnlyAToZ: awk tolower in the C locale folds A..Z and nothing else.
func TestLowerASCIIFoldsOnlyAToZ(t *testing.T) {
	if got := lowerASCII("AZ@[ÁÉmixed"); got != "az@[ÁÉmixed" {
		t.Errorf("lowerASCII = %q", got)
	}
}

// TestFirstCellCompactDropsEveryBlank: the compact form removes every C-locale blank and keeps other runes.
func TestFirstCellCompactDropsEveryBlank(t *testing.T) {
	trimmed, compact := firstCell("|  D 1\t\vx  é | second |")
	if trimmed != "D 1\t\vx  é" || compact != "D1xé" {
		t.Errorf("firstCell = %q, %q", trimmed, compact)
	}
}
