package cishard

import (
	"fmt"
	"sort"
	"strings"
)

// reportLines are the two report-only lines printed on every run, with a zero when there is nothing to report, so a
// zero proves the stream was looked at. A package whose tests all skip is a package-level pass, which `shard-join.sh
// --strict-skip` cannot see: the test-level skips are counted here from the stream.
func reportLines(st streamInfo) []string {
	total := 0
	var skipped []string
	for _, p := range sortedKeys(st.skips) {
		total += st.skips[p]
		skipped = append(skipped, fmt.Sprintf("%s: %d", p, st.skips[p]))
	}
	events := 0
	for _, n := range st.unknown {
		events += n
	}
	return []string{
		fmt.Sprintf("Go tests skipped: %d — [%s]", total, strings.Join(skipped, ", ")),
		fmt.Sprintf("unknown actions: %d — [%s]", events, strings.Join(sortedKeys(st.unknown), ", ")),
	}
}

// sortedKeys returns the keys of m in byte order.
func sortedKeys(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
