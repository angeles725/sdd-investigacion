package kit

import (
	"errors"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
)

// Typed states of ResolveStateFile (bash rc 1, 2, 3). Absent, ambiguous and unusable input stay three distinct
// states (kit CLAUDE.md section 7).
var (
	ErrStateAbsent    = errors.New("kit: no state file")
	ErrStateAmbiguous = errors.New("kit: ambiguous state files")
	ErrStateUsage     = errors.New("kit: state resolver usage")
)

// ResolveOptions mirrors `resolve_state_file [-H] <dir> [--focus <slug>]`.
type ResolveOptions struct {
	FollowDir bool   // -H: follow a symlinked <dir> (find -H)
	FocusSet  bool   // --focus was given
	Focus     string // its slug (empty with FocusSet is a usage error)
}

const stateMaxDepth = 3 // find -maxdepth 3

// findState mirrors `find [-H] dir -maxdepth 3 -name pat -not -name '*.template.md' -not -path '*/.git/*'`:
// no -type filter (a directory named like a state file is listed), symlinks are never descended except the
// start point under -H, unreadable subtrees are skipped, and the .git test runs on the whole printed path.
func findState(dir string, follow bool, pat string) []string {
	var out []string
	trimmed := strings.TrimRight(dir, "/")
	visit := func(p, name string, isDir bool) {
		ok, _ := path.Match(pat, name)
		if !ok || strings.HasSuffix(name, ".template.md") {
			return
		}
		if Behaviour.FindNoTypeFilter { // F7, legacy: no -type filter, .git tested on the whole printed path
			if strings.Contains(p, "/.git/") {
				return
			}
		} else if isDir || strings.Contains(strings.TrimPrefix(p, trimmed), "/.git/") {
			return
		}
		out = append(out, p)
	}
	startIsDir := false
	if st, err := os.Stat(dir); err == nil {
		startIsDir = st.IsDir()
	}
	visit(dir, trimmed[strings.LastIndex(trimmed, "/")+1:], startIsDir)
	stat := os.Lstat
	if follow {
		stat = os.Stat
	}
	if st, err := stat(dir); err != nil || !st.IsDir() {
		return out
	}
	var walk func(p string, depth int)
	walk = func(p string, depth int) {
		ents, err := os.ReadDir(p)
		if err != nil {
			return
		}
		for _, e := range ents {
			ep := p + "/" + e.Name()
			if strings.HasSuffix(p, "/") {
				ep = p + e.Name()
			}
			visit(ep, e.Name(), e.IsDir())
			if e.IsDir() && depth < stateMaxDepth {
				walk(ep, depth+1)
			}
		}
	}
	walk(dir, 1)
	return out
}

// ListStateFiles is list_state_files: the RESEARCH-STATE*.md paths under dir (maxdepth 3, *.template.md and .git
// excluded) in C-locale order. A missing dir is ErrAbsentInput (bash prints nothing and returns 0, the same as an
// empty corpus: finding F6); an existing dir without state files returns an empty list and a nil error.
func ListStateFiles(dir string) ([]string, error) {
	if _, err := os.Lstat(dir); err != nil {
		return nil, ErrAbsentInput
	}
	out := findState(dir, false, "RESEARCH-STATE*.md")
	sort.Slice(out, func(i, j int) bool { return cLess(out[i], out[j]) })
	return out, nil
}

// ResolveStateFile is resolve_state_file: THE one state file a consumer should act on. Shallowest depth first,
// and within one depth the un-suffixed root RESEARCH-STATE.md beats every RESEARCH-STATE-<focus>.md; remaining
// ties go to the C-locale-first path. ErrStateAbsent: nothing found. ErrStateAmbiguous: equal-rank candidates in
// DIFFERENT directories; the returned path is still the C-first pick. ErrStateUsage: dir is not a directory or
// an empty focus slug.
func ResolveStateFile(dir string, opt ResolveOptions) (string, error) {
	if st, err := os.Stat(dir); dir == "" || err != nil || !st.IsDir() {
		return "", ErrStateUsage
	}
	pat := "RESEARCH-STATE*.md"
	if opt.FocusSet {
		if opt.Focus == "" {
			return "", ErrStateUsage
		}
		pat = "RESEARCH-STATE-" + opt.Focus + ".md"
	}
	found := findState(dir, opt.FollowDir, pat)
	if len(found) == 0 {
		return "", ErrStateAbsent
	}
	type ranked struct {
		depth, notRoot int
		path           string
	}
	rs := make([]ranked, len(found))
	for i, p := range found {
		rest := ""
		if len(p) > len(dir) {
			rest = p[len(dir):]
		}
		base := p[strings.LastIndex(p, "/")+1:]
		r := ranked{depth: strings.Count(rest, "/"), notRoot: 1, path: p}
		if base == "RESEARCH-STATE.md" {
			r.notRoot = 0
		}
		rs[i] = r
	}
	sort.Slice(rs, func(i, j int) bool {
		a, b := rs[i], rs[j]
		if a.depth != b.depth {
			return a.depth < b.depth
		}
		if a.notRoot != b.notRoot {
			return a.notRoot < b.notRoot
		}
		return cLess(a.path, b.path)
	})
	key := func(r ranked) string { return strconv.Itoa(r.depth) + "\t" + strconv.Itoa(r.notRoot) }
	first := rs[0]
	dir0 := dirOf(first.path)
	for _, r := range rs[1:] {
		if key(r) == key(first) && dirOf(r.path) != dir0 {
			return first.path, ErrStateAmbiguous
		}
	}
	return first.path, nil
}

// dirOf is `${p%/*}`: everything before the last slash, or p itself when it has none.
func dirOf(p string) string {
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[:i]
	}
	return p
}
