package consumers

import (
	"cmp"
	"slices"
)

// classStats is one row of the table.
type classStats struct {
	files, withRef, pairs, refs, selfOnly int
}

// stats folds the results of one class into a row.
func (sn scanned) stats(class string) classStats {
	var st classStats
	for _, r := range sn.results {
		if r.class != class {
			continue
		}
		st.files++
		st.pairs += len(r.refs)
		st.refs += r.total()
		if len(r.refs) > 0 {
			st.withRef++
		}
		if len(r.refs) == 0 && r.self > 0 {
			st.selfOnly++
		}
	}
	return st
}

// referencing is the results of one class that name at least one script, sorted by path.
func (sn scanned) referencing(class string) []fileResult {
	var out []fileResult
	for _, r := range sn.results {
		if r.class == class && len(r.refs) > 0 {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b fileResult) int { return cmp.Compare(a.path, b.path) })
	return out
}
