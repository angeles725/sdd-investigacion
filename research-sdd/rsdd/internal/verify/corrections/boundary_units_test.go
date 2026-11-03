package corrections

import (
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestBlockKeyBoundaries(t *testing.T) {
	for _, c := range []struct{ name, prefix, num string }{
		{"-block1.md", "", "1"},      // the dash at index 0 is still a prefix separator
		{"t-block12", "t", "12"},     // the digit run reaches the end of the name
		{"t-bloque007.md", "t", "7"}, // zero padding is removed
		{"a-block1-block2.md", "a-block1", "2"},
		{"t-block.md", "", ""}, // no digit run
		{"block1.md", "", ""},  // no dash
		{"t-block0.md", "t", "0"},
	} {
		if p, n := blockKey(c.name); p != c.prefix || n != c.num {
			t.Errorf("blockKey(%q) = %q,%q want %q,%q", c.name, p, n, c.prefix, c.num)
		}
	}
}

func TestSplitReadFieldsEdges(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"a|b", []string{"a", "b"}}, {"a|b|", []string{"a", "b"}}, {"a|", []string{"a"}}, {"|", []string{""}}, {"|a", []string{"", "a"}},
		{"", nil}, {"ab", []string{"ab"}}, {"a||b", []string{"a", "", "b"}},
	} {
		if got := splitReadFields(c.in, '|'); !reflect.DeepEqual(got, c.want) {
			t.Errorf("splitReadFields(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestReadFocusesRowWidth(t *testing.T) {
	got := readFocusesOf(t, files("FOCUSES.md",
		"| `three` | `aa-blockN.md` |\n"+ // 3 fields: the empty one before the first bar, the slug, one more cell
			"| `two` |\n"+ // 2 fields: no cell after the slug
			"| `four` | s | `bb-blockN.md` |\n"))
	if want := map[string]string{"three": "aa", "four": "bb"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNamesBlockEdges(t *testing.T) {
	for _, c := range []struct {
		line, c string
		want    bool
	}{
		{"B9", "9", true}, {"b9.", "9", true}, {"B8", "9", false}, {"B09", "9", true}, {"B0", "0", true},
		{"Block   ", "82", false}, {"Block \t", "82", false}, {"bloque ", "82", false}, {"B ", "82", false},
		{"B 82", "82", false}, {"Block 82", "82", true}, {"Bloque\t82", "82", true}, {"b82", "82", true},
		{"B", "82", false}, {"", "82", false}, {"xB82", "82", false}, {"B820", "82", false}, {"B82_", "82", true},
	} {
		if got := namesBlock(c.line, c.c); got != c.want {
			t.Errorf("namesBlock(%q, %q) = %v, want %v", c.line, c.c, got, c.want)
		}
	}
}

func TestAbbrevEdges(t *testing.T) {
	for _, c := range []struct {
		l    string
		i    int
		want bool
	}{
		{"fig. 3", 4, true}, // the abbreviation starts the line
		{"ab. 3", 3, false}, // two letters not on the list: the first byte must be read
		{"a. 3", 2, true},   // a single letter
		{"see fig. 3", 8, true},
		{"see (fig. 3", 9, true},
		{"x. y", 2, true},
		{". y", 1, false}, // nothing before the dot
		{"cf. 3", 3, true},
	} {
		if got := abbrev(c.l, c.i); got != c.want {
			t.Errorf("abbrev(%q, %d) = %v, want %v", c.l, c.i, got, c.want)
		}
	}
}

// The ok-partial summary counts every kind of unchecked declaration exactly once.
func TestUncheckedCountsAreExact(t *testing.T) {
	partial := func(n int, amb, warn int) string {
		return "   ok-partial " + strconv.Itoa(n) + " declared correction(s) NOT checked (ambiguous/missing target: " + strconv.Itoa(amb) + " AMBIG, " + strconv.Itoa(warn) + " WARN; 0 negated) — see WARN/AMBIG above\n"
	}
	for _, c := range []struct {
		name string
		m    map[string]string
		want string
	}{
		{"qualified focus without that block", files("aa-block4.md", "> Corrects `zz` [Block 9].\n", "zz-block1.md", plain(1)), partial(1, 0, 1)},
		{"no block of that number on disk", files("t-block4.md", "> Corrects [Block 9].\n"), partial(1, 0, 1)},
		{"number ambiguous across prefixes", files("cc-block4.md", "> Corrects [Block 1].\n", "aa-block1.md", plain(1), "zz-block1.md", plain(1)), partial(1, 0, 1)},
		{"two of them", files("t-block4.md", "> Corrects [Block 9] and [Block 8].\n"), partial(2, 0, 2)},
	} {
		t.Run(c.name, func(t *testing.T) {
			o := runCorpus(t, c.m)
			if o.code != 0 || !strings.Contains(o.stdout, c.want) {
				t.Errorf("want %q in:\n%s", c.want, o.stdout)
			}
		})
	}
}
