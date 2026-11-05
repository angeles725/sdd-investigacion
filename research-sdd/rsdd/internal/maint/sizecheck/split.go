package sizecheck

import (
	"sort"
	"strings"
)

// chunk is one suggested PR: the files it holds with their lines, and a note when one unit alone exceeds the budget.
type chunk struct {
	idx, lines int
	note       string
	files      []fileRow
}

const toolbelt = "research-sdd/toolbelt/"

// unitKey groups a test with the code it tests: a toolbelt test pairs with the SUT of the same basename anywhere under
// research-sdd/toolbelt/ (maint/ and lib/ too).
func unitKey(p string) string {
	d, b := "", p
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		d, b = p[:i], p[i+1:]
	}
	stem := func(s string) string {
		if i := strings.LastIndexByte(s, '.'); i >= 0 {
			return s[:i]
		}
		return s
	}
	switch {
	case strings.HasPrefix(p, toolbelt+"tests/") && strings.HasSuffix(p, ".test.sh"):
		return toolbelt + strings.TrimSuffix(b, ".test.sh")
	case strings.HasPrefix(p, toolbelt+"tests/"):
		return d + "/" + stem(b)
	case strings.HasPrefix(p, toolbelt):
		return toolbelt + stem(b)
	case strings.Contains(p, "/tests/") && strings.HasSuffix(p, ".test.sh"):
		return p[:strings.LastIndex(p, "/tests/")] + "/" + strings.TrimSuffix(b, ".test.sh")
	}
	if d == "" {
		d = "."
	}
	return d + "/" + stem(b)
}

type unit struct {
	key   string
	total int
	files []fileRow
}

// split packs the units, in key order, into chunks of at most budget lines: a unit that does not fit starts a new
// chunk, and one larger than the budget gets a chunk of its own marked single-unit-over-budget.
func split(files []fileRow, budget int) []chunk {
	rows := append([]fileRow(nil), files...)
	sort.SliceStable(rows, func(i, j int) bool { // `LC_ALL=C sort -k1,1 -k3,3`: unit key, then path
		ki, kj := unitKey(rows[i].path), unitKey(rows[j].path)
		if ki != kj {
			return ki < kj
		}
		return rows[i].path < rows[j].path
	})
	var units []*unit
	byKey := map[string]*unit{}
	for _, r := range rows {
		k := unitKey(r.path)
		u := byKey[k]
		if u == nil {
			u = &unit{key: k}
			byKey[k] = u
			units = append(units, u)
		}
		u.total += r.lines
		u.files = append(u.files, r)
	}
	var out []chunk
	cur := &chunk{idx: 1}
	open := false // the current chunk has been given a unit
	for _, u := range units {
		if cur.lines > 0 && cur.lines+u.total > budget {
			out = append(out, *cur)
			cur = &chunk{idx: cur.idx + 1}
		}
		cur.lines += u.total
		open = true
		cur.files = append(cur.files, u.files...)
		if u.total > budget {
			cur.note = "single-unit-over-budget"
			out = append(out, *cur)
			cur, open = &chunk{idx: cur.idx + 1}, false
		}
	}
	if open {
		out = append(out, *cur)
	}
	return out
}
