package sizecheck

import (
	"cmp"
	"path"
	"slices"
	"strings"
)

// State names of the verdict (the `size: <state>` line, the JSON "state").
const (
	stEmpty    = "empty-input"
	stExcluded = "all-excluded"
	stUnmeas   = "unmeasured"
	stOK       = "ok"
	stOver     = "over-budget"
	stRefuse   = "refuse"
)

// fileRow is a measured file.
type fileRow struct {
	lines, add, del int
	path, old       string
}

// exRow is an excluded file with the lines it would have counted.
type exRow struct {
	lines int
	path  string
}

// tally is the classified diff.
type tally struct {
	files                []fileRow // largest first
	excluded             []exRow
	unmeasured, renames  []string
	authored, adds, dels int
	exLines, exFiles     int
	nentries             int
}

const fixtureDir = "research-sdd/toolbelt/tests/fixtures/"

// excluded is pure DATA: fixture files other than the *.sh / *.py / *.mjs logic (stubs, shims, helpers are reviewed
// code), and lockfiles.
func excluded(p string) bool {
	if strings.HasPrefix(p, fixtureDir) {
		switch path.Ext(p) {
		case ".sh", ".py", ".mjs":
			// `fixtures/*.sh` is a shell glob: `*` matches `/` too, so any depth counts
			return false
		}
		return true
	}
	if strings.HasSuffix(p, ".lock") {
		return true
	}
	switch path.Base(p) {
	case "package-lock.json", "pnpm-lock.yaml", "go.sum":
		return true
	}
	return false
}

// classify sorts the entries into measured, excluded, unmeasured (binary) and pure renames.
func classify(es []entry) tally {
	t := tally{nentries: len(es)}
	for _, e := range es {
		if excluded(e.path) {
			n := 0
			if e.add != "-" {
				n = num(e.add) + num(e.del)
			}
			t.exLines += n
			t.exFiles++
			t.excluded = append(t.excluded, exRow{n, e.path})
			continue
		}
		if e.add == "-" || e.del == "-" {
			t.unmeasured = append(t.unmeasured, e.path)
			continue
		}
		a, d := num(e.add), num(e.del)
		if e.old != "" && a == 0 && d == 0 {
			t.renames = append(t.renames, e.old+" -> "+e.path)
			continue
		}
		t.authored += a + d
		t.adds += a
		t.dels += d
		t.files = append(t.files, fileRow{a + d, a, d, e.path, e.old})
	}
	// `LC_ALL=C sort -k1,1nr -k4,4`: most lines first, then the path bytewise
	slices.SortStableFunc(t.files, func(a, b fileRow) int {
		return cmp.Or(cmp.Compare(b.lines, a.lines), strings.Compare(a.path, b.path))
	})
	return t
}

// verdict is the state of a tally against the budget and the hard limit.
func (t tally) verdict(budget, hard int) string {
	switch {
	case t.nentries == 0:
		return stEmpty
	case len(t.files) == 0 && t.exFiles > 0 && len(t.renames) == 0:
		return stExcluded
	case len(t.files) == 0:
		return stUnmeas
	case t.authored <= budget:
		return stOK
	case t.authored <= hard:
		return stOver
	}
	return stRefuse
}
