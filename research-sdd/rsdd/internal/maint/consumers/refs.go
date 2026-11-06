package consumers

import (
	"fmt"
	"io"
	"sort"
)

// pair is one line of --refs.
type pair struct {
	class, file, script string
	count               int
}

// pairs lists every (file, script) pair with its count, sorted by class, file and script.
func (sn scanned) pairs() []pair {
	var out []pair
	for _, r := range sn.results {
		for name, n := range r.refs {
			out = append(out, pair{r.class, r.path, name, n})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.class != b.class {
			return a.class < b.class
		}
		if a.file != b.file {
			return a.file < b.file
		}
		return a.script < b.script
	})
	return out
}

// writeRefs prints the pairs, tab-separated. It returns false when there is nothing to print, so the caller says
// so on stderr: an empty output must not read as "did not look".
func writeRefs(w io.Writer, sn scanned) bool {
	ps := sn.pairs()
	for _, p := range ps {
		fmt.Fprintf(w, refsLine, p.class, p.file, p.script, p.count)
	}
	return len(ps) > 0
}
