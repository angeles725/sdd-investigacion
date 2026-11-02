package gate

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"strings"
)

// A native `find -H`: the gate used to fork find (and grep, basename and stat per path) for every scan, which took
// more than 300 s on a large corpus (#2168). The walk keeps what the old commands did, and only that:
//   - -H: a symlink on the command line (the root) is followed, one met while descending is not (it is a symlink
//     entry, never a directory or a regular file);
//   - children are visited in directory order (the order getdents returns them, not sorted) and depth first, so the
//     paths come out in the order find prints them and the first of two equal mtimes wins the same way;
//   - an unreadable directory or a vanished entry makes the walk incomplete (status 1, find's exit code) and the
//     walk goes on; a cancelled context ends it with status 124, the code `timeout` reports, keeping what it found.

type walkCtl int

const (
	walkOn   walkCtl = iota // keep going (and descend into a directory)
	walkSkip                // do not descend into this entry
	walkStop                // end the whole walk
)

// walkNoLimit is find's absence of -maxdepth.
const walkNoLimit = -1

type walker struct {
	ctx      context.Context
	rc       int
	errs     []string // find's own error lines, in the order they happened
	maxDepth int
	entry    func(root, path string) // test seam, see retroHooks.onEntry
	root     string
}

// walkResult is what a walk reports: find's exit status and the error lines find would have printed.
type walkResult struct {
	rc   int
	errs []string
}

// fail records a traversal error the way find reports it (UTF-8 quoting, strerror capitalisation).
func (w *walker) fail(path string, err error) {
	w.rc = max(w.rc, 1)
	reason := err.Error()
	var pe *fs.PathError
	if errors.As(err, &pe) {
		reason = pe.Err.Error()
	}
	if reason != "" {
		reason = strings.ToUpper(reason[:1]) + reason[1:]
	}
	w.errs = append(w.errs, "find: \u2018"+path+"\u2019: "+reason)
}

// walkVisit is called for every entry: its path, its file type bits (symlinks are not followed) and its depth
// (0 for the root).
type walkVisit func(p string, typ fs.FileMode, depth int) walkCtl

// findWalk walks root and returns find's exit status: 0, 1 when something could not be read, 124 when ctx ended.
func findWalk(ctx context.Context, root string, maxDepth int, entry func(root, path string), visit walkVisit) walkResult {
	w := &walker{ctx: ctx, maxDepth: maxDepth, entry: entry, root: root}
	li, err := os.Lstat(root)
	if err != nil {
		w.fail(root, err)
		return walkResult{rc: w.rc, errs: w.errs}
	}
	typ := li.Mode().Type()
	if typ&fs.ModeSymlink != 0 { // -H: the command-line argument is followed when it resolves
		if si, err := os.Stat(root); err == nil {
			typ = si.Mode().Type()
		}
	}
	ctl := visit(root, typ, 0)
	if ctl == walkOn && typ.IsDir() && (maxDepth == walkNoLimit || maxDepth > 0) {
		w.descend(root, 0, visit)
	}
	return walkResult{rc: w.rc, errs: w.errs}
}

// descend reads dir and visits its entries. It reports whether the walk must end.
func (w *walker) descend(dir string, depth int, visit walkVisit) bool {
	f, err := os.Open(dir)
	if err != nil {
		w.fail(dir, err)
		return false
	}
	ents, err := f.ReadDir(-1) // directory order, unsorted
	_ = f.Close()
	if err != nil {
		w.fail(dir, err)
	}
	prefix := dir + "/"
	if dir == "/" {
		prefix = "/"
	}
	for _, e := range ents {
		if w.ctx.Err() != nil {
			w.rc = 124
			return true
		}
		p := prefix + e.Name()
		if w.entry != nil {
			w.entry(w.root, p)
			if w.ctx.Err() != nil {
				w.rc = 124
				return true
			}
		}
		typ := e.Type()
		switch visit(p, typ, depth+1) {
		case walkStop:
			return true
		case walkSkip:
			continue
		}
		if typ.IsDir() && (w.maxDepth == walkNoLimit || depth+1 < w.maxDepth) {
			if w.descend(p, depth+1, visit) {
				return true
			}
		}
	}
	return false
}

// hasGitSegment is `-path '*/.git/*'`: the path has a .git component that is not its last one.
func hasGitSegment(p string) bool { return strings.Contains(p, "/.git/") }

// matchRetroPath is `-path '*/retros/*.md'`.
func matchRetroPath(p string) bool {
	i := strings.Index(p, "/retros/")
	return i >= 0 && strings.HasSuffix(p[i+len("/retros/"):], ".md")
}

// matchIndexName is `-iname '*index*.md'` on a base name.
func matchIndexName(name string) bool {
	l := strings.ToLower(name)
	i := strings.Index(l, "index")
	return i >= 0 && strings.HasSuffix(l[i+len("index"):], ".md")
}
