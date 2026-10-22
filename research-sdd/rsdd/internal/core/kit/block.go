package kit

import (
	"errors"
	"os"
	"regexp"
	"strings"
)

// Typed states of the nested-worktree probe (bash rc 2 and 3).
var (
	ErrNotDir         = errors.New("kit: not a directory")
	ErrIncompleteWalk = errors.New("kit: incomplete traversal")
)

// FilterResult mirrors block_file_filter: grep's status verbatim (0 match, 1 no-match, 2 error), never laundered.
type FilterResult struct {
	Lines    []string
	Status   int
	Examined int // lines read: 0 with Status 1 is empty-input, > 0 with Status 1 is no-match
	Err      error
}

const blockRe = `(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$`

// BlockFileFilter is block_file_filter [-v] [prefix] over newline-separated candidate paths. The prefix is
// interpolated UNESCAPED into the ERE, exactly like the bash lib; the ERE dialect is Go's POSIX one
// (regexp.CompilePOSIX), the closest to grep -E (GNU extensions such as back-references are an error here).
// Lines are matched in the C locale: [[:alnum:]] is ASCII.
func BlockFileFilter(input string, invert bool, prefix string) FilterResult {
	re := `(^|/)[^/]+-` + blockRe
	if prefix != "" {
		re = `(^|/)` + prefix + blockRe
	}
	rx, err := regexp.CompilePOSIX(re)
	if err != nil {
		return FilterResult{Status: 2, Err: err}
	}
	var ls []string
	if input != "" {
		ls = strings.Split(strings.TrimSuffix(input, "\n"), "\n")
	}
	res := FilterResult{Examined: len(ls)}
	for _, l := range ls {
		if rx.MatchString(l) != invert {
			res.Lines = append(res.Lines, l)
		}
	}
	if len(res.Lines) == 0 {
		res.Status = 1
	}
	return res
}

func firstLine(path string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return "", false
	}
	l, _, _ := strings.Cut(string(b), "\n")
	return l, true
}

// NestedWorktreeRoots is block_files_nested_worktree_roots: "<root>/.claude/worktrees" always, plus every nested
// .git FILE proven to belong to a linked worktree (its gitdir holds a commondir file AND its gitdir/gitdir
// back-pointer names the same file). Nested clones, submodules and stale pointers are not roots. Roots after the
// first come in sorted order (bash: readdir order). ErrNotDir is rc 2; ErrIncompleteWalk is rc 3 with the roots
// found so far.
func NestedWorktreeRoots(root string) ([]string, error) {
	return nestedWorktreeRoots(root, os.ReadDir)
}

// nestedWorktreeRoots is NestedWorktreeRoots with the directory reader injected (tests walk "/" without touching it).
func nestedWorktreeRoots(root string, readDir func(string) ([]os.DirEntry, error)) ([]string, error) {
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		return nil, &msgError{"block-files: nested_worktree_roots: not a directory: " + root, ErrNotDir}
	}
	// `${_root%/}` strips ONE slash, so "root//" keeps one (its prune path then never matches find's output: a
	// bash quirk kept for parity). A root of "/" is the filesystem root, never "": bash cannot probe it (find "" fails,
	// rc 3 "under  —", finding F15); Go walks it from "/".
	skip := "/.claude/worktrees"
	if root != "/" {
		root = strings.TrimSuffix(root, "/")
		skip = root + "/.claude/worktrees"
	}
	out := []string{skip}
	incomplete := false
	var walk func(dir string)
	walk = func(dir string) {
		ents, err := readDir(dir)
		if err != nil {
			incomplete = true
			return
		}
		for _, e := range ents {
			p := dir + "/" + e.Name()
			if strings.HasSuffix(dir, "/") { // find prints children of "dir/" as "dir/child"
				p = dir + e.Name()
			}
			switch {
			case p == skip:
			case e.IsDir() && e.Name() == ".git":
			case e.IsDir():
				walk(p)
			case e.Type().IsRegular() && e.Name() == ".git":
				if r, ok := worktreeRoot(p, root); ok {
					out = append(out, r)
				}
			}
		}
	}
	walk(root)
	if incomplete {
		return out, &msgError{"block-files: nested_worktree_roots: find exited 1 under " + root +
			" — worktrees under unreadable directories may be missing", ErrIncompleteWalk}
	}
	return out, nil
}

// ownGit says the .git file (whose directory is wt) is the probe root's own, never a nested worktree. For the
// filesystem root "/" the directory of "/.git" is "" after the suffix cut.
func ownGit(wt, root string) bool { return wt == root || (root == "/" && wt == "") }

// worktreeRoot decides whether the .git file gf marks a linked worktree.
func worktreeRoot(gf, root string) (string, bool) {
	wt := strings.TrimSuffix(gf, "/.git")
	if ownGit(wt, root) {
		return "", false
	}
	line, ok := firstLine(gf)
	if !ok {
		return "", false
	}
	gd, ok := strings.CutPrefix(line, "gitdir:")
	if !ok {
		return "", false
	}
	gd = strings.TrimPrefix(gd, " ")
	if !strings.HasPrefix(gd, "/") {
		gd = wt + "/" + gd
	}
	if st, err := os.Stat(gd + "/commondir"); err != nil || !st.Mode().IsRegular() {
		return "", false
	}
	bp, ok := firstLine(gd + "/gitdir")
	if !ok {
		return "", false
	}
	if !strings.HasPrefix(bp, "/") {
		bp = gd + "/" + bp
	}
	a, e1 := os.Stat(bp)
	b, e2 := os.Stat(gf)
	if e1 != nil || e2 != nil || !os.SameFile(a, b) {
		return "", false
	}
	return wt, true
}

// PathInNestedWorktree is block_files_path_in_nested_worktree: p is a root or lies under one. Empty roots never match.
func PathInNestedWorktree(p string, roots []string) bool {
	for _, r := range roots {
		if r != "" && (p == r || strings.HasPrefix(p, r+"/")) {
			return true
		}
	}
	return false
}
