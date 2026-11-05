package migratebacklogs

import (
	"io/fs"
	"path"
	"sort"
	"strings"
)

// maxDepth is how deep a corpus is searched: a file at target/a/b/FILE is at depth 3, like find -maxdepth 3.
const maxDepth = 3

// inventory is what a corpus directory holds, as slash-separated paths relative to it in byte order.
type inventory struct {
	states   []string // RESEARCH-STATE*.md, *.template.md excluded
	focuses  []string // FOCUSES.md
	scanErr  error    // the walk could not read part of the tree
	rootFail error    // the corpus directory itself cannot be listed
}

func isStateFile(name string) bool {
	return len(name) >= len("RESEARCH-STATE.md") && strings.HasPrefix(name, "RESEARCH-STATE") &&
		strings.HasSuffix(name, ".md") && !strings.HasSuffix(name, ".template.md")
}

// scan lists the state files and the FOCUSES.md files of the corpus. A directory is searched down to maxDepth,
// `.git` is never entered, and a symlink to a directory is not followed (find's default); the corpus directory
// itself may be a symlink.
func scan(fsys fs.FS) inventory {
	var inv inventory
	if _, err := fs.ReadDir(fsys, "."); err != nil {
		inv.rootFail = err
		return inv
	}
	inv.scanErr = fs.WalkDir(fsys, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" || p != "." && strings.Count(p, "/")+1 >= maxDepth {
				return fs.SkipDir
			}
			return nil
		}
		switch name := path.Base(p); {
		case isStateFile(name):
			inv.states = append(inv.states, p)
		case name == "FOCUSES.md":
			inv.focuses = append(inv.focuses, p)
		}
		return nil
	})
	sort.Strings(inv.states)
	sort.Strings(inv.focuses)
	return inv
}

// labelOf is the name a state file goes by in the report: the part after `RESEARCH-STATE-`, or "(root)".
func labelOf(rel string) string {
	b := strings.TrimSuffix(path.Base(rel), ".md")
	if rest, ok := strings.CutPrefix(b, "RESEARCH-STATE-"); ok && rest != "" {
		return rest
	}
	return "(root)"
}
