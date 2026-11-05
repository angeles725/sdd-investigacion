package writercheck

import (
	"os"
	"path/filepath"
	"strings"
)

// change is one `git diff --name-status` record: the status (A, M, D, R100, ...), the path and, for a rename or a
// copy, the old path (path is then the new one).
type change struct {
	status, path, old string
}

// rangeSpec is what the diff is taken against: a worktree run diffs the merge-base against the working tree, a
// committed run diffs BASE...HEAD.
type rangeSpec struct {
	worktree bool
	base     string // the merge-base (worktree) or the base ref (committed)
	head     string // the head ref (committed)
}

// args are the diff arguments after the subcommand options.
func (r rangeSpec) args() []string {
	if r.worktree {
		return []string{r.base}
	}
	return []string{r.base + "..." + r.head}
}

// failedMsg is the degraded reason of a failed diff of the given kind.
func (r rangeSpec) failedMsg(kind string) string {
	if r.worktree {
		return kind + " failed against " + r.base
	}
	return kind + " failed for " + r.base + "..." + r.head
}

// parseNameStatus reads `git diff --name-status -z`: a status word, then one path (two for a rename or a copy).
func parseNameStatus(z string) []change {
	var out []change
	f := strings.Split(strings.TrimSuffix(z, "\x00"), "\x00")
	for i := 0; i < len(f) && f[i] != ""; {
		st, n := f[i], 2
		if st[0] == 'R' || st[0] == 'C' {
			n = 3
		}
		if i+n > len(f) {
			break
		}
		if n == 3 {
			out = append(out, change{status: st, old: f[i+1], path: f[i+2]})
		} else {
			out = append(out, change{status: st, path: f[i+1]})
		}
		i += n
	}
	return out
}

// diffSet is the changed files of a range and the lines they add.
type diffSet struct {
	changes []change
	added   []addedLine
}

// loadDiff reads the changes and the added lines of the range. A worktree run also lists the untracked files, as
// added files whose every line is added. The second result is the degraded reason when git failed.
func (c *ctx) loadDiff(r rangeSpec) (diffSet, string) {
	var d diffSet
	flags := []string{"-c", "core.quotePath=false"}
	ns := c.git(append(append(append([]string(nil), flags...), "diff", "--name-status", "-z", "-M"), r.args()...)...)
	if !ns.OK() {
		return d, r.failedMsg("git diff")
	}
	d.changes = parseNameStatus(ns.Out)
	ud := c.git(append(append(append([]string(nil), flags...), "diff", "-U0", "--no-color", "-M"), r.args()...)...)
	if !ud.OK() {
		return d, r.failedMsg("git diff -U0")
	}
	d.added = parseAdded(ud.Out)
	if r.worktree {
		for _, f := range c.untracked() {
			d.changes = append(d.changes, change{status: "A", path: f})
			d.added = append(d.added, c.fileLines(f)...)
		}
	}
	return d, ""
}

// untracked lists the untracked, not ignored files (a failing listing is no files, as the bash pipeline was).
func (c *ctx) untracked() []string {
	r := c.git("-c", "core.quotePath=false", "ls-files", "-o", "--exclude-standard", "-z")
	if !r.OK() {
		return nil
	}
	var out []string
	for _, f := range strings.Split(r.Out, "\x00") {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}

// fileLines are the lines of an untracked file as added lines, numbered from 1. Only a regular file the name-kill
// scan reads is opened.
func (c *ctx) fileLines(rel string) []addedLine {
	if scan, _ := scanned(rel); !scan {
		return nil
	}
	p := filepath.Join(c.repo, rel)
	if fi, err := os.Stat(p); err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil || len(b) == 0 {
		return nil
	}
	var out []addedLine
	for i, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		out = append(out, addedLine{file: rel, line: i + 1, text: l})
	}
	return out
}
