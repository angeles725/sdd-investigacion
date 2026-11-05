package writercheck

import (
	"crypto/sha1" //nolint:gosec // git's own blob id, not a security digest
	"fmt"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// bindingHeader is the first line of a teeth log: what the log is tied to. tree is the git blob id of the text
// "<path> <blob id>" per changed file (the worktree's current contents, or the head commit's), sorted, a deleted or
// renamed-away path as "<path> DELETED". The same bytes give the same tree whichever clone or commit they sit in.
// head is informational (the commit HEAD points at).
func (c *ctx) bindingHeader(r rangeSpec, changes []change) string {
	var lines []string
	for _, ch := range changes {
		p := ch.path
		switch {
		case ch.status[0] == 'D':
			lines = append(lines, ch.path+" DELETED")
			continue
		case ch.status[0] == 'R':
			lines = append(lines, ch.old+" DELETED")
		}
		lines = append(lines, p+" "+c.blobID(r, p))
	}
	sort.Strings(lines)
	head := "unknown"
	if h := c.git("rev-parse", "HEAD"); h.OK() {
		head = strings.TrimRight(h.Out, "\n")
	}
	return fmt.Sprintf("# writer-check: head=%s tree=%s", head, blobOf(strings.Join(lines, "\n")+terminator(lines)))
}

// terminator is the newline that ends the last line (nothing for no lines).
func terminator(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return "\n"
}

// blobID is the id of a changed file's content: `git hash-object` of the working file, or the blob at HEAD:path of
// the head ref; MISSING when git has none.
func (c *ctx) blobID(r rangeSpec, p string) string {
	var res kitmaint.Res
	if r.worktree {
		res = c.git("hash-object", "--", p)
	} else {
		res = c.git("rev-parse", "-q", "--verify", r.head+":"+p)
	}
	if id := strings.TrimRight(res.Out, "\n"); res.OK() && id != "" {
		return id
	}
	return "MISSING"
}

// blobOf is `git hash-object --stdin` of s: the sha1 of "blob <len>\0" followed by the bytes.
func blobOf(s string) string {
	h := sha1.New() //nolint:gosec // see above
	fmt.Fprintf(h, "blob %d\x00%s", len(s), s)
	return fmt.Sprintf("%x", h.Sum(nil))
}
