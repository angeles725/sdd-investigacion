package archtest

import (
	"reflect"
	"strconv"
	"testing"
)

const reason = "long enough reason"

func debtLine(p string, n int, kind string) string {
	return p + " " + strconv.Itoa(n) + " " + kind + " " + reason + "\n"
}

func TestUnlistedHardBoundary(t *testing.T) {
	r := check(t, map[string]string{"s.go": gen(400), "h.go": gen(401)}, "")
	want := []string{
		"h.go: 401 lines, over 400. A new file over 400 lines cannot be listed: split it.",
		"s.go: 400 lines, over 200 and not listed. Split it, or add this line to modularity-debt.txt:\ns.go 400 accepted <reason>",
	}
	if !reflect.DeepEqual(r.Violations, want) || r.Over != 2 {
		t.Errorf("violations = %q Over=%d", r.Violations, r.Over)
	}
}

func TestListedAtOrBelowRecordedPasses(t *testing.T) {
	debt := debtLine("a.go", 300, "legacy") + debtLine("b.go", 300, "legacy") + debtLine("c.go", 250, "legacy")
	r := check(t, map[string]string{"a.go": gen(300), "b.go": gen(299), "c.go": gen(201)}, debt)
	if len(r.Violations) != 0 {
		t.Errorf("violations = %q", r.Violations)
	}
	if r.Entries != 3 || r.Over != 3 || r.Lowerable != 2 {
		t.Errorf("want Entries=3 Over=3 Lowerable=2, got %+v", r)
	}
}

func TestGrewBoundaryRecordedPlusOne(t *testing.T) {
	debt := debtLine("a.go", 300, "legacy")
	if r := check(t, map[string]string{"a.go": gen(300)}, debt); len(r.Violations) != 0 {
		t.Errorf("equal to recorded must pass: %q", r.Violations)
	}
	r := check(t, map[string]string{"a.go": gen(301)}, debt)
	want := "a.go: grew from 300 to 301 lines. Split it, or change its line in modularity-debt.txt to:\na.go 301 legacy " + reason
	if len(r.Violations) != 1 || r.Violations[0] != want {
		t.Errorf("violations = %q, want [%q]", r.Violations, want)
	}
}

func TestGrewPastHardLimit(t *testing.T) {
	debt := debtLine("a.go", 400, "legacy") + debtLine("b.go", 450, "legacy")
	r := check(t, map[string]string{"a.go": gen(401), "b.go": gen(451)}, debt)
	want := []string{
		"a.go: grew from 400 to 401 lines and is over 400. A file over 400 lines may not grow: split it first.",
		"b.go: grew from 450 to 451 lines and is over 400. A file over 400 lines may not grow: split it first.",
	}
	if !reflect.DeepEqual(r.Violations, want) {
		t.Errorf("violations = %q", r.Violations)
	}
}

func TestLegacyAboveHardMayShrinkButPassesAtRecorded(t *testing.T) {
	debt := debtLine("a.go", 500, "legacy") + debtLine("b.go", 500, "legacy")
	r := check(t, map[string]string{"a.go": gen(500), "b.go": gen(450)}, debt)
	if len(r.Violations) != 0 || r.Lowerable != 1 {
		t.Errorf("got %+v", r)
	}
}

func TestListedNoLongerOverSoftLimit(t *testing.T) {
	debt := debtLine("a.go", 250, "legacy") + debtLine("b.go", 250, "legacy")
	r := check(t, map[string]string{"a.go": gen(200), "b.go": gen(201)}, debt)
	want := []string{"a.go: 200 lines, no longer over 200. Delete this line from modularity-debt.txt:\na.go 250 legacy " + reason}
	if !reflect.DeepEqual(r.Violations, want) {
		t.Errorf("violations = %q", r.Violations)
	}
}

func TestListedButNotProduction(t *testing.T) {
	debt := debtLine("gone.go", 300, "legacy") + debtLine("x_test.go", 300, "legacy")
	r := check(t, map[string]string{"x_test.go": gen(300), "ok.go": gen(1)}, debt)
	want := []string{
		"gone.go: listed but not a production Go file in this tree. Delete this line from modularity-debt.txt:\ngone.go 300 legacy " + reason,
		"x_test.go: listed but not a production Go file in this tree. Delete this line from modularity-debt.txt:\nx_test.go 300 legacy " + reason,
	}
	if !reflect.DeepEqual(r.Violations, want) {
		t.Errorf("violations = %q", r.Violations)
	}
}

func TestAcceptedEntryAboveHardLimit(t *testing.T) {
	debt := "# c\n" + debtLine("a.go", 400, "accepted") + debtLine("b.go", 401, "accepted")
	r := check(t, map[string]string{"a.go": gen(300), "b.go": gen(401)}, debt)
	want := []string{"modularity-debt.txt:3: an accepted entry may not be above 400 lines (b.go 401): split the file."}
	if !reflect.DeepEqual(r.Violations, want) {
		t.Errorf("violations = %q", r.Violations)
	}
}

func TestListedEntryAtFirstMiddleLastPosition(t *testing.T) {
	files := map[string]string{"a.go": gen(300), "b.go": gen(300), "c.go": gen(300)}
	for name, bad := range map[string]string{"a.go": "first", "b.go": "middle", "c.go": "last"} {
		t.Run(bad, func(t *testing.T) {
			debt := ""
			for _, p := range []string{"a.go", "b.go", "c.go"} {
				n := 300
				if p == name {
					n = 299 // file grew past the recorded count
				}
				debt += debtLine(p, n, "legacy")
			}
			r := check(t, files, debt)
			if len(r.Violations) != 1 || r.Violations[0][:len(name)+10] != name+": grew fro" {
				t.Errorf("violations = %q", r.Violations)
			}
		})
	}
}
