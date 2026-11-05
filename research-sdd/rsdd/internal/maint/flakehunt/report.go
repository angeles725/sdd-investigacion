package flakehunt

import (
	"fmt"
	"io"
)

// Classifications of a suite that failed.
const (
	kindFlaky  = "flaky"  // failed in some runs
	kindBroken = "broken" // failed in every run: a defect, not a flake
)

// finding is a suite worth an issue.
type finding struct{ suite, kind string }

// tally is the totals line of a hunt.
type tally struct{ flaky, broken, stable, skipped int }

// measured is how many suites were actually measured: a hunt where every suite skipped looked at nothing.
func (t tally) measured() int { return t.flaky + t.broken + t.stable }

// classify walks the suites in list order and prints one line per flaky or broken suite. A suite listed twice is
// walked twice over the same counters, as the bash tool did.
func (h *hunt) classify(w io.Writer) (found []finding, t tally) {
	for _, s := range h.suites {
		f := h.fails[s]
		switch {
		case f == 0 && h.skips[s] == h.c.runs:
			t.skipped++
		case f == 0:
			t.stable++
		case f == h.c.runs:
			t.broken++
			found = append(found, finding{s, kindBroken})
			fmt.Fprintf(w, "broken: %s failed %d/%d — %s\n", s, f, h.c.runs, h.first[s])
		default:
			t.flaky++
			found = append(found, finding{s, kindFlaky})
			fmt.Fprintf(w, "flaky: %s failed %d/%d — %s\n", s, f, h.c.runs, h.first[s])
		}
	}
	return found, t
}

// printTotals is the summary and the results path.
func (h *hunt) printTotals(w io.Writer, t tally) {
	fmt.Fprintf(w, "Flake hunt: runs=%d suites=%d load=%d flaky=%d broken=%d stable=%d skipped=%d\n",
		h.c.runs, len(h.suites), h.c.load, t.flaky, t.broken, t.stable, t.skipped)
	fmt.Fprintf(w, "Results: %s\n", h.results)
}
