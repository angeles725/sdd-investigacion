package migratebacklogs

import (
	"fmt"
	"sort"
)

// manualLines folds the findings of one file into one typed line per distinct reason, in byte order of the
// reason: `MANUAL <label> <reason> rows=<N> first-line=<L>`. first-line is the line of the first finding (0 for a
// finding about the whole file).
func manualLines(label string, items []manualItem) []string {
	count := map[string]int{}
	first := map[string]int{}
	var reasons []string
	for _, it := range items {
		if count[it.reason] == 0 {
			reasons = append(reasons, it.reason)
			first[it.reason] = it.line
		}
		count[it.reason]++
	}
	sort.Strings(reasons)
	out := make([]string, 0, len(reasons))
	for _, r := range reasons {
		out = append(out, fmt.Sprintf("MANUAL %s %s rows=%d first-line=%d", label, r, count[r], first[r]))
	}
	return out
}

// summaryLine closes every run, so a zero can be told from a run that never looked (CLAUDE.md section 7).
func summaryLine(files, proposals, manual int) string {
	return fmt.Sprintf("migrate-backlogs: %d file(s) inspected · %d with a mechanical proposal · %d MANUAL line(s)", files, proposals, manual)
}
