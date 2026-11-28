package cishard

import "sort"

// defaultWeight is the weight in seconds of a package the durations file does not list (the measured median that
// run-all.sh uses for a suite).
const defaultWeight = 6

// assignment is the result of the weighted assignment.
type assignment struct {
	shares   [][]string // shares[k] is the sorted package list of shard k+1
	loads    []int      // loads[k] is the predicted seconds of shard k+1
	unlisted []string   // the packages that took defaultWeight, sorted
}

// weighted is one package with the weight it is placed by.
type weighted struct {
	pkg string
	sec int
}

// lighter orders longest first, ties by path (byte order, LC_ALL=C).
func lighter(a, b weighted) bool {
	if a.sec != b.sec {
		return a.sec > b.sec
	}
	return a.pkg < b.pkg
}

// assign is the rule of `run-all.sh --shard I/N`: packages longest first (ties: path) each go to the least-loaded shard
// (ties: the lowest shard number). The result depends only on the set of packages, never on their input order, so
// every shard computes the same cover. pkgs holds no duplicate (parsePackages refuses one).
func assign(pkgs []string, weights map[string]int, n int) assignment {
	a := assignment{shares: make([][]string, n), loads: make([]int, n)}
	order := make([]weighted, 0, len(pkgs))
	for _, p := range pkgs {
		sec, listed := weights[p]
		if !listed {
			sec = defaultWeight
			a.unlisted = append(a.unlisted, p)
		}
		order = append(order, weighted{p, sec})
	}
	sort.Strings(a.unlisted)
	sort.Slice(order, func(i, j int) bool { return lighter(order[i], order[j]) })
	for _, w := range order {
		best := 0
		for k := 1; k < n; k++ {
			if a.loads[k] < a.loads[best] {
				best = k
			}
		}
		a.loads[best] += w.sec
		a.shares[best] = append(a.shares[best], w.pkg)
	}
	for k := range a.shares {
		sort.Strings(a.shares[k])
	}
	return a
}
