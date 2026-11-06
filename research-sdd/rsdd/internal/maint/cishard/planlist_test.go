package cishard

import (
	"reflect"
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
