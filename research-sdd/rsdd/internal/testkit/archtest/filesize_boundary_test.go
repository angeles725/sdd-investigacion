package archtest

import (
	"reflect"
	"testing"
)

func sameStrings(a, b []string) bool { return len(a) == 0 && len(b) == 0 || reflect.DeepEqual(a, b) }

// Both sides of every comparison the ratchet makes on a listed file.
func TestListedEntryBoundaries(t *testing.T) {
	const why = " " + reason
	cases := []struct {
		name      string
		lines     int // current size of a.go
		recorded  int
		kind      string
		want      []string
		lowerable int
	}{
		{"at the soft limit is no longer debt", 200, 300, "legacy",
			[]string{"a.go: 200 lines, no longer over 200. Delete this line from modularity-debt.txt:\na.go 300 legacy" + why}, 0},
		{"one over the soft limit is still debt", 201, 300, "legacy", nil, 1},
		{"at the recorded count passes", 300, 300, "legacy", nil, 0},
		{"one over the recorded count grew", 301, 300, "legacy",
			[]string{"a.go: grew from 300 to 301 lines. Split it, or change its line in modularity-debt.txt to:\na.go 301 legacy" + why}, 0},
		{"growth up to the hard limit may be recorded", 400, 399, "accepted",
			[]string{"a.go: grew from 399 to 400 lines. Split it, or change its line in modularity-debt.txt to:\na.go 400 accepted" + why}, 0},
		{"growth past the hard limit may not", 401, 400, "legacy",
			[]string{"a.go: grew from 400 to 401 lines and is over 400. A file over 400 lines may not grow: split it first."}, 0},
		{"accepted at the hard limit passes", 400, 400, "accepted", nil, 0},
		{"accepted above the hard limit fails", 401, 401, "accepted",
			[]string{"modularity-debt.txt:1: an accepted entry may not be above 400 lines (a.go 401): split the file."}, 0},
		{"legacy above the hard limit passes at its count", 500, 500, "legacy", nil, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := check(t, map[string]string{"a.go": gen(c.lines)}, debtLine("a.go", c.recorded, c.kind))
			if !sameStrings(r.Violations, c.want) || r.Lowerable != c.lowerable {
				t.Errorf("violations = %q lowerable = %d, want %q and %d", r.Violations, r.Lowerable, c.want, c.lowerable)
			}
		})
	}
}

// Update mode at the same edges: what is deleted, lowered, and left alone.
func TestUpdateBoundaries(t *testing.T) {
	spaced := "a.go  300\tlegacy   " + reason + "\n"
	cases := []struct {
		name  string
		lines int
		debt  string
		want  string
	}{
		{"at the soft limit the line is deleted", 200, debtLine("a.go", 300, "legacy"), ""},
		{"one over the soft limit the count is lowered", 201, debtLine("a.go", 300, "legacy"), debtLine("a.go", 201, "legacy")},
		{"at the recorded count the line keeps its bytes", 300, spaced, spaced},
		{"one under the recorded count the line is rewritten", 299, spaced, debtLine("a.go", 299, "legacy")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			changed, got := update(t, map[string]string{"a.go": gen(c.lines)}, c.debt)
			if got != c.want || changed != (c.want != c.debt) {
				t.Errorf("changed = %v, file = %q, want %q", changed, got, c.want)
			}
		})
	}
}

func TestFourFieldsMakeAnEntryAndThreeDoNot(t *testing.T) {
	entries, bad := parseDebt("a.go 300 legacy abcdefghij\n")
	if len(bad) != 0 || len(entries) != 1 || entries[0].Reason != "abcdefghij" {
		t.Errorf("entries = %+v bad = %q, want one entry with a one-word reason", entries, bad)
	}
	if entries, bad := parseDebt("a.go 300 legacy\n"); len(bad) != 1 || len(entries) != 0 {
		t.Errorf("entries = %+v bad = %q, want three fields refused", entries, bad)
	}
}
