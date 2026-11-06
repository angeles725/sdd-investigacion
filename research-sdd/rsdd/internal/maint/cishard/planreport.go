package cishard

import (
	"fmt"
	"io"
	"strings"
)

// noteAssignment writes the stderr notes of one plan: the degraded state or the balance, the packages weighted at the
// default, the stale durations entries and the shard's size. Stdout carries only the packages.
func noteAssignment(w io.Writer, spec shardSpec, total, mine int, loads []int, unlisted, stale []string, degraded string) {
	if len(unlisted) > 0 {
		fmt.Fprintf(w, "ci-shard: durations — %d of %d planned package(s) not in the durations file, weighted %d s each: %s\n",
			len(unlisted), total, defaultWeight, strings.Join(unlisted, ", "))
	}
	if len(stale) > 0 {
		fmt.Fprintf(w, "ci-shard: stale duration entries %d — [%s]\n", len(stale), strings.Join(stale, ", "))
	}
	fmt.Fprintf(w, "ci-shard: shard %d/%d — %d of %d packages\n", spec.i, spec.n, mine, total)
	if degraded != "" {
		fmt.Fprintf(w, "ci-shard: DEGRADED — %s; assigning round-robin by name (still a disjoint, complete cover)\n", degraded)
		return
	}
	lo, hi := loads[0], loads[0]
	for _, l := range loads {
		if l < lo {
			lo = l
		}
		if l > hi {
			hi = l
		}
	}
	fmt.Fprintf(w, "ci-shard: balance — duration-weighted, predicted %d s for this shard (all %d shards: min %d s, max %d s)\n",
		loads[spec.i-1], spec.n, lo, hi)
}
