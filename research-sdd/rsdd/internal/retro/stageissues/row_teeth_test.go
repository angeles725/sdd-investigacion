package stageissues

import (
	"strings"
	"testing"
)

// Mutation-killing tests of the row counters and the entry-form warning (kit issue #2592). They run the Go command
// in-process through the shared box (the fake gh is the one bash script the golden tests already need) and assert
// the exact lines the behaviour must print.

// runGoCase runs one case through the Go command only.
func runGoCase(t *testing.T, c dcase) result {
	t.Helper()
	return runGo(t, mkBox(t, c.resolve(t)), c)
}

func hasSummary(out, unclassifiable string) bool {
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "summary: ") && strings.Contains(l, " unclassifiable="+unclassifiable+" ") {
			return true
		}
	}
	return false
}

const shippedOne = "<!-- review-status: applied · a · PARTIAL — shipped: 1 -->"

// rowCountCases are runs whose --apply summary must count one unclassifiable row.
func rowCountCases() []dcase {
	good := row("1", "first good delta title here", "x.md", "B1", "fix", "LOW")
	apply := []string{"--apply"}
	return []dcase{
		{name: "teeth/pipe-id", retro: doc(pending, good, row(`6\|7`, "escaped pipe in the id here", "x.md", "B1", "fix", "LOW")), args: apply},
		{name: "teeth/dotted-id", retro: doc(pending, good, row("1.2", "dotted id delta title here", "x.md", "B1", "fix", "LOW")), args: apply},
		{name: "teeth/bare-title", retro: doc(pending, row("2", "LOW", "x.md", "B1", "fix", "LOW")), args: apply},
		{name: "teeth/dismissed-malformed", retro: doc("<!-- review-status: applied · a · PARTIAL — shipped: 1; DISMISSED: () -->", good, row("2", "second good delta title here", "x.md", "B1", "fix", "LOW")), args: apply},
	}
}

func TestSummaryCountsEachUnclassifiableRow(t *testing.T) {
	for _, c := range rowCountCases() {
		t.Run(c.name, func(t *testing.T) {
			r := runGoCase(t, c)
			if r.RC != 0 || !hasSummary(r.Stdout, "1") {
				t.Errorf("rc=%d, want a summary with unclassifiable=1; stdout:\n%s", r.RC, r.Stdout)
			}
		})
	}
}

// A row that was counted open and then refused for its title leaves the open count, so a retro whose other rows
// are all shipped still reports "all rows are shipped".
func TestUnusableTitleRowIsNotOpen(t *testing.T) {
	c := dcase{name: "teeth/shipped-and-bare", retro: doc(shippedOne, row("1", "first good delta title here", "x.md", "B1", "fix", "LOW"), row("2", "LOW", "x.md", "B1", "fix", "LOW"))}
	r := runGoCase(t, c)
	want := "no-match: delta section found but all rows are shipped (skipped: 1)\n"
	if !strings.Contains(r.Stderr, want) {
		t.Errorf("stderr lacks %q:\n%s", want, r.Stderr)
	}
}

func entryRetro(headings ...string) string {
	s := pending + "\n# retro\n\n## Proposed kit deltas\n\n"
	for i, h := range headings {
		s += "### " + h + " — Entry form delta title number " + string(rune('A'+i)) + "\n\nBody.\n\n"
	}
	return s
}

const entryWarnPrefix = "WARN: r.md: only "

func TestEntryWarnOnlyWhenSomeEntryIsTracked(t *testing.T) {
	mixed := runGoCase(t, dcase{name: "teeth/entries-mixed", retro: entryRetro("D1", "**D2**")})
	want := entryWarnPrefix + "1 of 2 '### … —' entries have a usable ID token"
	if !strings.Contains(mixed.Stderr, want) {
		t.Errorf("mixed entries: stderr lacks %q:\n%s", want, mixed.Stderr)
	}
	// every entry untrackable: the run is refused as unclassifiable and the count-by-hand warning stays quiet
	none := runGoCase(t, dcase{name: "teeth/entries-untrackable", retro: entryRetro("**D1**", "[D2]")})
	if strings.Contains(none.Stderr, entryWarnPrefix) {
		t.Errorf("untrackable entries: unexpected entry warning:\n%s", none.Stderr)
	}
	if !strings.Contains(none.Stderr, "unclassifiable: delta section found but contains neither row-table rows") {
		t.Errorf("untrackable entries: expected the unclassifiable refusal:\n%s", none.Stderr)
	}
	// all entries trackable: no warning
	all := runGoCase(t, dcase{name: "teeth/entries-all", retro: entryRetro("D1", "D2")})
	if strings.Contains(all.Stderr, entryWarnPrefix) {
		t.Errorf("trackable entries: unexpected entry warning:\n%s", all.Stderr)
	}
}
