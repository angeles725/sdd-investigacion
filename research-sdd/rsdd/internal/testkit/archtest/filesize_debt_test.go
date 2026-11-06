package archtest

import (
	"fmt"
	"strings"
	"testing"
)

func badMsg(lineno int, what string) string {
	return fmt.Sprintf("modularity-debt.txt:%d: %s; expected \"<path> <lines> <legacy|accepted> <reason of at least 10 characters>\", entries sorted by path", lineno, what)
}

func TestParseDebtAcceptsEntriesCommentsAndBlanks(t *testing.T) {
	text := "# header\n\na.go 300 legacy reason of ten\nb.go 250 accepted  spaced   reason text  \n"
	es, bad := parseDebt(text)
	if len(bad) != 0 || len(es) != 2 {
		t.Fatalf("es=%v bad=%v", es, bad)
	}
	if e := es[1]; e.Path != "b.go" || e.Lines != 250 || e.Kind != "accepted" || e.Reason != "spaced   reason text" || e.LineNo != 4 {
		t.Errorf("entry 2 = %+v", e)
	}
}

func TestReasonLengthBoundary(t *testing.T) {
	_, bad9 := parseDebt("a.go 300 legacy 123456789\n")
	if len(bad9) != 1 || bad9[0] != badMsg(1, "reason is shorter than 10 characters") {
		t.Errorf("9 characters: %q", bad9)
	}
	es, bad10 := parseDebt("a.go 300 legacy 1234567890\n")
	if len(bad10) != 0 || len(es) != 1 {
		t.Errorf("10 characters: es=%v bad=%v", es, bad10)
	}
}

func TestMalformedLines(t *testing.T) {
	for _, tt := range []struct{ name, line, what string }{
		{"three fields", "a.go 300 legacy", "malformed line, fewer than four fields"},
		{"zero count", "a.go 0 legacy long enough reason", `"0" is not a positive line count`},
		{"negative count", "a.go -4 legacy long enough reason", `"-4" is not a positive line count`},
		{"not a number", "a.go many legacy long enough reason", `"many" is not a positive line count`},
		{"unknown kind", "a.go 300 temporary long enough reason", `unknown kind "temporary"`},
	} {
		t.Run(tt.name, func(t *testing.T) {
			es, bad := parseDebt("# c\n" + tt.line + "\n")
			if len(es) != 0 || len(bad) != 1 || bad[0] != badMsg(2, tt.what) {
				t.Errorf("es=%v bad=%q", es, bad)
			}
		})
	}
}

func TestOrderingFirstMiddleLastAndSingle(t *testing.T) {
	ok := func(p string) string { return p + " 300 legacy long enough reason\n" }
	// unsorted pair at the start, in the middle, at the end
	cases := map[string]struct {
		text   string
		lineno int
	}{
		"first":  {ok("b.go") + ok("a.go") + ok("c.go"), 2},
		"middle": {ok("a.go") + ok("c.go") + ok("b.go") + ok("d.go"), 3},
		"last":   {ok("a.go") + ok("b.go") + ok("c.go") + ok("a1.go"), 4},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, bad := parseDebt(c.text)
			if len(bad) != 1 || !strings.HasPrefix(bad[0], fmt.Sprintf("modularity-debt.txt:%d: ", c.lineno)) || !strings.Contains(bad[0], "(unsorted)") {
				t.Errorf("bad = %q", bad)
			}
		})
	}
	if es, bad := parseDebt(ok("only.go")); len(es) != 1 || len(bad) != 0 {
		t.Errorf("single entry: es=%v bad=%v", es, bad)
	}
}

func TestDuplicatePathFails(t *testing.T) {
	_, bad := parseDebt("a.go 300 legacy long enough reason\na.go 300 legacy long enough reason\n")
	if len(bad) != 1 || bad[0] != badMsg(2, "duplicate path a.go") {
		t.Errorf("bad = %q", bad)
	}
}

func TestMalformedLinesSurfaceThroughCheck(t *testing.T) {
	r := check(t, map[string]string{"a.go": gen(3)}, "a.go 300 sometimes long enough reason\n")
	if len(r.Violations) == 0 || r.Violations[0] != badMsg(1, `unknown kind "sometimes"`) {
		t.Errorf("violations = %q", r.Violations)
	}
	if r.Entries != 0 {
		t.Errorf("a malformed line is not an entry read, got %d", r.Entries)
	}
}
