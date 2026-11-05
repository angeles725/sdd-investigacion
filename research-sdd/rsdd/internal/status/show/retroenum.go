package show

import (
	"os"
	"sort"
	"strings"
)

// retroMaxDepth is find's -maxdepth for the retro enumeration: the target is depth 0.
const retroMaxDepth = 4

// retroFiles is the retro enumeration of the RETRO-DUE derivation and of issues_due_gate:
//
//	find "$target" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' -not -iname '*index*.md' -type f
//
// in byte order, with the paths spelled as find would print them (the target as the caller wrote it). It is the
// predicate of sweep-retros.sh. rc is find's exit status: 1 when a directory could not be read, with the files that
// were seen still listed (a partial listing is never the complete retro set; the callers say so).
func (c *ctx) retroFiles() (paths []string, rc int) {
	var walk func(disp string, depth int)
	walk = func(disp string, depth int) {
		ents, err := os.ReadDir(c.abs(disp))
		if err != nil {
			rc = 1
		}
		for _, e := range ents {
			p := strings.TrimSuffix(disp, "/") + "/" + e.Name()
			switch {
			case e.IsDir():
				if depth+1 < retroMaxDepth {
					walk(p, depth+1)
				}
			case e.Type().IsRegular() && isRetroPath(p, e.Name()):
				paths = append(paths, p)
			}
		}
	}
	if st, err := os.Lstat(c.abs(c.target)); err == nil && st.Mode()&os.ModeSymlink != 0 {
		return nil, 0 // find does not follow a symlinked start point without -H: it lists the link itself, no retro
	}
	walk(c.target, 0)
	sort.Strings(paths)
	return paths, rc
}

// isRetroPath is the find predicate over a printed path and its base name.
func isRetroPath(p, base string) bool {
	if !strings.HasSuffix(p, ".md") || strings.Contains(p, "/.git/") { // -path '*/.git/*'
		return false
	}
	if !strings.Contains(p, "/retros/") { // -path '*/retros/*.md': the `*` after it may be empty or cross slashes
		return false
	}
	low := strings.ToLower(base) // -iname '*index*.md'
	return !(strings.HasSuffix(low, ".md") && strings.Contains(strings.TrimSuffix(low, ".md"), "index"))
}
