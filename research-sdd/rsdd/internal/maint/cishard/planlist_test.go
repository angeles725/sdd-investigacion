package cishard

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// Guard-to-test table (planlist.go): the three non-plannable states -> TestParsePackagesStates; list edges ->
// TestParsePackagesEdges; duplicates and inner blanks are refused -> TestParsePackagesRefusals.

func TestParsePackagesEdges(t *testing.T) {
	for _, c := range []struct {
		name, in string
		want     []string
	}{
		{"single with newline", "a\n", []string{"a"}},
		{"single without final newline", "a", []string{"a"}},
		{"first middle last", "first\nmiddle\nlast\n", []string{"first", "middle", "last"}},
		{"no final newline keeps the last", "first\nmiddle\nlast", []string{"first", "middle", "last"}},
		{"blank lines and padding are skipped", "\n a \n\n\tb\t\n", []string{"a", "b"}},
		{"CRLF", "a\r\nb\r\n", []string{"a", "b"}},
	} {
		got, issue := parsePackages([]byte(c.in))
		if issue != nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v %+v", c.name, got, issue)
		}
	}
}

func TestParsePackagesStates(t *testing.T) {
	for _, c := range []struct{ name, in, state string }{
		{"zero bytes", "", "empty-input"},
		{"only blanks", "\n \n\t\n", "no-match"},
	} {
		got, issue := parsePackages([]byte(c.in))
		if issue == nil || issue.state != c.state || issue.detail == "" || got != nil {
			t.Errorf("%s: %v %+v", c.name, got, issue)
		}
	}
}

// Only ASCII space, tab and CR pad a line. Any other Unicode space (U+00A0, U+0085, U+2003), at the edge or inside, is
// refused: a path holding one must never read as a clean path.
func TestParsePackagesRefusesUnicodeSpace(t *testing.T) {
	for _, sp := range []string{" ", "\u0085", " "} {
		for _, c := range []struct{ name, in, tok string }{
			{"inner", "a\nb" + sp + "c\n", "b" + sp + "c"},
			{"leading", "a\n" + sp + "b\n", sp + "b"},
			{"trailing, last line without newline", "a\nb" + sp, "b" + sp},
			{"single", sp, sp},
		} {
			_, issue := parsePackages([]byte(c.in))
			if issue == nil || issue.state != "invalid" || !strings.HasSuffix(issue.detail, fmt.Sprintf("%q holds whitespace", c.tok)) {
				t.Errorf("%q %s: %+v", sp, c.name, issue)
			}
		}
	}
}

func TestParsePackagesRefusals(t *testing.T) {
	for _, c := range []struct{ name, in, detail string }{
		{"duplicate in first and last position", "a\nb\na\n", "line 3: \"a\" is listed twice (first at line 1)"},
		{"duplicate with padding", "a\n b \nb", "line 3: \"b\" is listed twice (first at line 2)"},
		{"inner whitespace", "a\nb c\n", "line 2: \"b c\" holds whitespace"},
		{"inner tab at the last line", "a\nb\tc", "line 2: \"b\\tc\" holds whitespace"},
	} {
		got, issue := parsePackages([]byte(c.in))
		if issue == nil || issue.state != "invalid" || issue.detail != c.detail || got != nil {
			t.Errorf("%s: %v %+v", c.name, got, issue)
		}
	}
}
