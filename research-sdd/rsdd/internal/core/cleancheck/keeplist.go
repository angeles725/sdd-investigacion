package cleancheck

import (
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// keepRel is where a target declares the untracked files it keeps on purpose.
const keepRel = ".research-sdd/keep.txt"

// keepList is the parsed keep.txt: one glob per entry, a trailing slash keeping a whole tree.
type keepList struct {
	globs   []string
	present bool
}

// parseKeep reads the keep.txt grammar: blank lines and lines whose first non-blank character is # are comments,
// everything from the first " #" is a reason, CR and surrounding blanks are dropped, and NUL bytes vanish as they do
// in a shell read.
func parseKeep(src string) []string {
	var globs []string
	for _, line := range strings.Split(strings.ReplaceAll(src, "\x00", ""), "\n") {
		line = strings.TrimSuffix(line, "\r")
		line = strings.TrimLeft(line, shellx.WsClass)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.Index(line, " #"); i >= 0 {
			line = line[:i]
		}
		if line = strings.TrimRight(line, shellx.WsClass); line != "" {
			globs = append(globs, line)
		}
	}
	return globs
}

// kept reports whether keep.txt keeps the path (relative to the target). keep.txt itself is always kept.
func (k keepList) kept(rel string) bool {
	if rel == keepRel {
		return true
	}
	for _, g := range k.globs {
		if strings.HasSuffix(g, "/") {
			if globMatch(g+"*", rel) {
				return true
			}
		} else if globMatch(g, rel) {
			return true
		}
	}
	return false
}

// loadKeep reads <target>/.research-sdd/keep.txt. A missing file is the typed ABSENT-KEEPLIST line (information); one
// that exists and cannot be read is a refused run.
func (r *run) loadKeep() bool {
	path := r.targetP + "/" + keepRel
	info, err := os.Stat(path)
	if err != nil {
		r.absent(AbsentKeepList, path, "ABSENT-KEEPLIST "+path)
		return true
	}
	if !info.Mode().IsRegular() { // a directory or a FIFO: reading it would fail or never end
		return r.refuse("keep-list is not a readable file: " + path)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return r.refuse("keep-list is not a readable file: " + path)
	}
	r.keep = keepList{globs: parseKeep(string(b)), present: true}
	return true
}
