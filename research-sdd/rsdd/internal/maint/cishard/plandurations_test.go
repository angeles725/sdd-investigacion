package cishard

import (
	"reflect"
	"testing"
)

// Guard-to-test table (plandurations.go): the line grammar -> TestDurationsInvalidLines; comments and blanks ->
// TestDurationsValid; stale entries -> TestDurationsStale; the list edges -> TestDurationsEdges.

var known = map[string]bool{"a": true, "b": true, "c": true}

func TestDurationsValid(t *testing.T) {
	d := parseDurations([]byte("# header\n\na 3\n  b   999999  \n"), known)
	if len(d.invalid) != 0 || len(d.stale) != 0 || !reflect.DeepEqual(d.weights, map[string]int{"a": 3, "b": 999999}) {
		t.Errorf("%+v", d)
	}
}

func TestDurationsInvalidLines(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a\n", "line 1: \"a\" has no seconds"},
		{"a 3 x\n", "line 1: \"a\" has extra text after the seconds"},
		{"a 0\n", "line 1: \"a\" has seconds \"0\" (need a positive integer, at most 999999)"},
		{"a 007\n", "line 1: \"a\" has seconds \"007\" (need a positive integer, at most 999999)"},
		{"a -4\n", "line 1: \"a\" has seconds \"-4\" (need a positive integer, at most 999999)"},
		{"a 1000000\n", "line 1: \"a\" has seconds \"1000000\" (need a positive integer, at most 999999)"},
		{"a 1.5\n", "line 1: \"a\" has seconds \"1.5\" (need a positive integer, at most 999999)"},
		{"a 3\na 4\n", "line 2: \"a\" is listed twice"},
	} {
		d := parseDurations([]byte(c.in), known)
		if len(d.invalid) == 0 || d.invalid[len(d.invalid)-1] != c.want {
			t.Errorf("%q: %v", c.in, d.invalid)
		}
	}
}

func TestDurationsEdges(t *testing.T) {
	// invalid in first, middle and last position, the last without a final newline: every one is named, in order
	d := parseDurations([]byte("a x\nb 0\n# note\nc"), known)
	want := []string{
		"line 1: \"a\" has seconds \"x\" (need a positive integer, at most 999999)",
		"line 2: \"b\" has seconds \"0\" (need a positive integer, at most 999999)",
		"line 4: \"c\" has no seconds",
	}
	if !reflect.DeepEqual(d.invalid, want) {
		t.Errorf("%v", d.invalid)
	}
	// a single valid entry with no final newline
	one := parseDurations([]byte("c 9"), known)
	if len(one.invalid) != 0 || one.weights["c"] != 9 {
		t.Errorf("%+v", one)
	}
}

func TestDurationsStale(t *testing.T) {
	d := parseDurations([]byte("a 3\ngone 5\nalso/gone 6\n"), known)
	if len(d.invalid) != 0 || !reflect.DeepEqual(d.stale, []string{"gone", "also/gone"}) || !reflect.DeepEqual(d.weights, map[string]int{"a": 3}) {
		t.Errorf("%+v", d)
	}
}

func TestDurationsEmptyReadsAsNothing(t *testing.T) {
	for _, in := range []string{"", "\n\n", "# only a comment\n"} {
		d := parseDurations([]byte(in), known)
		if len(d.weights)+len(d.stale)+len(d.invalid) != 0 {
			t.Errorf("%q: %+v", in, d)
		}
	}
}
