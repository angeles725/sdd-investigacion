package reviewslices

import (
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// forEach runs fn for every scenario. Scenarios that share a builder share ONE repository (the tool is report-only,
// which every run asserts), so a hundred scenarios cost a few dozen repositories; the groups run in parallel, the
// scenarios of a group in turn, each with its own git wrapper and counter files.
func forEach(t *testing.T, fn func(t *testing.T, r *repo, sc scenario)) {
	t.Helper()
	all := scenarios()
	shims := writeShims(t, all)
	groups := map[string][]scenario{}
	var order []string
	seen := map[string]bool{}
	for _, sc := range all {
		if seen[sc.name] {
			t.Fatalf("duplicate scenario name %q", sc.name)
		}
		seen[sc.name] = true
		k := builderName(sc)
		if _, ok := groups[k]; !ok {
			order = append(order, k)
		}
		groups[k] = append(groups[k], sc)
	}
	for _, k := range order {
		scs := groups[k]
		t.Run(k, func(t *testing.T) {
			t.Parallel()
			r := scs[0].world(t)
			r.shims = shims
			scs[0].build(r)
			for _, sc := range scs {
				t.Run(sc.name, func(t *testing.T) {
					r.t = t
					fn(t, r, sc)
				})
			}
		})
	}
}

// builderName identifies the builder function: a named builder is shared, a closure is its own site (commitsOf
// returns closures, so a scenario uses it only through a named builder).
func builderName(sc scenario) string {
	if sc.light {
		return "light"
	}
	n := runtime.FuncForPC(reflect.ValueOf(sc.build).Pointer()).Name()
	return n[strings.LastIndex(n, "reviewslices.")+len("reviewslices."):]
}
