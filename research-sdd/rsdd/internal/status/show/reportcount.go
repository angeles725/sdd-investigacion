package show

import (
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// The figures of the default report that the other modes do not derive.

// firstDigitRun is `grep -iE key | grep -oE '[0-9]+' | head -1` over lines: the first run of digits of the first
// line that mentions key (ASCII case-blind) and has one.
func firstDigitRun(lines []string, key string) string {
	for _, l := range lines {
		if !strings.Contains(lowerASCII(l), key) {
			continue
		}
		if d := strings.IndexAny(l, "0123456789"); d >= 0 {
			e := d
			for e < len(l) && isDigit(l[e]) {
				e++
			}
			return l[d:e]
		}
	}
	return ""
}

// coveredBlocks is the claimed count of ## Coverage: the first number of the first "covered blocks" line.
func (c *ctx) coveredBlocks() string {
	return firstDigitRun(splitLines(sectionBody(c.stateText(), "## Coverage")), "covered blocks")
}

// invCount is inv_count: the first number of the first "read-only investigable" line of ## Stop control.
func (c *ctx) invCount() string {
	return firstDigitRun(splitLines(c.stopctl()), "read-only investigable")
}

// pendingByPriority is the `ph` pipeline: open rows whose status is exactly `pending` (one leading and one trailing
// bold mark removed), per priority.
func (c *ctx) pendingByPriority() string {
	n := map[string]int{}
	for _, l := range splitLines(c.rows(false)) {
		f := strings.Split(l, "\t")
		if len(f) < 3 || strings.Contains(f[1], "~~") {
			continue
		}
		if strings.TrimSuffix(strings.TrimPrefix(f[2], "**"), "**") == "pending" {
			n[f[0]]++
		}
	}
	return fmt.Sprintf("high=%d medium=%d low=%d", n["high"], n["medium"], n["low"])
}

// onDisk is the number of block files the state file's focus owns: its prefix, else its range, else every one.
func (c *ctx) onDisk() int {
	pfx, _ := kit.DeriveFocusPrefix(c.abs(c.state))
	if pfx.Value != "" {
		return len(c.listBlockFiles(c.corpus, pfx.Value))
	}
	rng, _ := kit.DeriveFocusRange(c.abs(c.state))
	diags, _ := kit.FocusRangeReport(c.abs(c.state)) // RANGE-REPORT
	for _, dg := range diags {
		fmt.Fprintf(c.s.Err, "status: %s: %s\n", dg.Kind, dg.Text)
	}
	if rng.State == kit.RangeOK {
		s, err := kit.ScanFocusRange(c.abs(c.corpus), rng.Lo, rng.Hi, c.abs(c.state)) // RANGE-DISPLAY-COUNT
		if err != nil {
			return 0
		}
		return s.Count
	}
	return len(c.listBlockFiles(c.corpus, ""))
}
