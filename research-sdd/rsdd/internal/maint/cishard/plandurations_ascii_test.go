package cishard

import (
	"fmt"
	"reflect"
	"testing"
)

// Guard-to-test table (plandurations.go, the grammar of run-all.sh `read -r path sec extra` with the default IFS):
// '\r' belongs to the token -> TestDurationsCRLFIsInvalidInEveryPosition; only ASCII space and tab separate ->
// TestDurationsOnlyAsciiSpaceAndTabSeparate; a stale duplicate is invalid -> TestDurationsStaleDuplicateIsInvalid.

func TestDurationsCRLFIsInvalidInEveryPosition(t *testing.T) {
	bad := func(n int, p, sec string) string {
		return fmt.Sprintf("line %d: %q has seconds %q (need a positive integer, at most 999999)", n, p, sec)
	}
	d := parseDurations([]byte("a 3\r\nb 4\r\nc 5\r\n"), known)
	if want := []string{bad(1, "a", "3\r"), bad(2, "b", "4\r"), bad(3, "c", "5\r")}; !reflect.DeepEqual(d.invalid, want) || len(d.weights) != 0 {
		t.Errorf("%v", d.invalid)
	}
	// a single-line file; and a lone CR line is one token with no seconds
	if one := parseDurations([]byte("a 3\r"), known); !reflect.DeepEqual(one.invalid, []string{bad(1, "a", "3\r")}) {
		t.Errorf("%v", one.invalid)
	}
	if lone := parseDurations([]byte("a 3\n\r\n"), known); !reflect.DeepEqual(lone.invalid, []string{fmt.Sprintf("line 2: %q has no seconds", "\r")}) {
		t.Errorf("%v", lone.invalid)
	}
	// a comment ending in CR is still a comment
	if c := parseDurations([]byte("# note\r\na 3\n"), known); len(c.invalid) != 0 || c.weights["a"] != 3 {
		t.Errorf("%+v", c)
	}
}

func TestDurationsOnlyAsciiSpaceAndTabSeparate(t *testing.T) {
	for _, sep := range []string{" ", "\u0085", " "} {
		tok := "a" + sep + "3"
		d := parseDurations([]byte(tok+"\n"), known)
		if want := []string{fmt.Sprintf("line 1: %q has no seconds", tok)}; !reflect.DeepEqual(d.invalid, want) {
			t.Errorf("separator %q: %v", sep, d.invalid)
		}
	}
	if d := parseDurations([]byte("a\t3\n  b \t 4 \t\n"), known); len(d.invalid) != 0 || d.weights["a"] != 3 || d.weights["b"] != 4 {
		t.Errorf("tab and space: %+v", d)
	}
}

// Declared divergence from run-all.sh (tool-registry.d/ci-shard.md): the bash names a stale path listed twice twice and
// goes on; here a duplicate line is a defect of the file whether or not the path is stale.
func TestDurationsStaleDuplicateIsInvalid(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"first", "gone 1\ngone 2\na 3\nb 4\n", "line 2: \"gone\" is listed twice"},
		{"last, no final newline", "a 3\nb 4\ngone 1\ngone 2", "line 4: \"gone\" is listed twice"},
	} {
		d := parseDurations([]byte(c.in), known)
		if !reflect.DeepEqual(d.invalid, []string{c.want}) {
			t.Errorf("%s: %v", c.name, d.invalid)
		}
	}
}
