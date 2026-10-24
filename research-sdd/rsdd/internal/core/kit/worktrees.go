package kit

import (
	"bufio"
	"errors"
	"os"
	"sort"
	"strings"
)

// Typed outcomes of NestedWorktreeRoots (bash rc 2 and 3).
var (
	// ErrNotDirectory: the scan root is not a directory.
	ErrNotDirectory = errors.New("kit: not a directory")
	// ErrIncomplete: part of the tree could not be read; the roots found so far are still returned (an incomplete
	// probe is not "none", kit CLAUDE.md section 7).
	ErrIncomplete = errors.New("kit: incomplete traversal")
)

// NestedWorktreeRoots is block_files_nested_worktree_roots: the directories a corpus scan of root must skip because
// they hold another checkout of the corpus. The first entry is always root+"/.claude/worktrees" (excluded whether
// or not it exists); then every directory whose ".git" FILE proves a linked worktree (isLinkedWorktree), in
// C-locale order where bash prints find's readdir order. A nested clone (".git" directory), a submodule and a
// stale worktree are never roots, and root's own ".git" never makes root a root.
//
// The walk mirrors `find -H root -mindepth 1 (-path root/.claude/worktrees -prune) -o (-type d -name .git -prune)
// -o (-type f -name .git -print0)`: a symlinked root is followed, nothing below it is. One trailing slash of root
// is dropped (`${root%/}`). The prune compares the path exactly where find's -path would glob (DEFERRED.md).
func NestedWorktreeRoots(root string) ([]string, error) {
	if !IsDirOS(root) {
		return nil, &msgError{"block-files: nested_worktree_roots: not a directory: " + root, ErrNotDirectory}
	}
	root = strings.TrimSuffix(root, "/")
	fixed := root + "/.claude/worktrees"
	var nested []string
	complete := walkGitFiles(root, fixed, func(gf string) {
		if dir := dirOf(gf); dir != root && isLinkedWorktree(gf) {
			nested = append(nested, dir)
		}
	})
	sort.Slice(nested, func(i, j int) bool { return cLess(nested[i], nested[j]) })
	out := append([]string{fixed}, nested...)
	if !complete {
		return out, &msgError{"block-files: nested_worktree_roots: find exited 1 under " + root +
			" — worktrees under unreadable directories may be missing", ErrIncomplete}
	}
	return out, nil
}

// walkGitFiles calls visit for every regular file named .git under dir, never descending into a .git directory,
// a symlink or the pruned path. It reports whether every directory could be read.
func walkGitFiles(dir, pruned string, visit func(string)) bool {
	ents, err := os.ReadDir(dir)
	complete := err == nil
	for _, e := range ents {
		p := dir + "/" + e.Name()
		switch {
		case p == pruned:
		case e.Name() == ".git":
			if e.Type().IsRegular() {
				visit(p)
			}
		case e.IsDir():
			complete = walkGitFiles(p, pruned, visit) && complete
		}
	}
	return complete
}

// isLinkedWorktree is the probe of one ".git" file gf. Its "gitdir:" target (relative targets resolve against gf's
// directory) must hold a `commondir` regular file, which the VCS writes for linked worktrees only, AND a `gitdir`
// back-pointer naming gf itself (same inode, kit issue #1301: commondir alone is forgeable). The gitdir TEXT is
// never trusted. Anything that cannot be proven is not a worktree (a false BLOCK is recoverable, a false ALLOW is
// not).
func isLinkedWorktree(gf string) bool {
	line, ok := firstLine(gf)
	gd, isGitdir := strings.CutPrefix(line, "gitdir:")
	if !ok || !isGitdir {
		return false
	}
	gd = joinRelative(dirOf(gf), strings.TrimPrefix(gd, " "))
	if st, err := os.Stat(gd + "/commondir"); err != nil || !st.Mode().IsRegular() {
		return false
	}
	bp, ok := firstLine(gd + "/gitdir")
	if !ok {
		return false
	}
	a, errA := os.Stat(joinRelative(gd, bp))
	b, errB := os.Stat(gf)
	return errA == nil && errB == nil && os.SameFile(a, b) // [ bp -ef gf ]
}

// joinRelative is `case p in /*) ;; *) p="$base/$p"`: no cleaning, exactly the bash concatenation.
func joinRelative(base, p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return base + "/" + p
}

// firstLine is `{ IFS= read -r line < f; } 2>/dev/null || [ -n "$line" ]`: the bytes before the first newline;
// false when the file cannot be read, or when it holds no newline and nothing before EOF.
func firstLine(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil {
		return line, line != ""
	}
	return strings.TrimSuffix(line, "\n"), true
}

// PathInNestedWorktree is block_files_path_in_nested_worktree: p is one of roots or lies under one. Empty entries
// are skipped; an empty roots list never matches.
func PathInNestedWorktree(p string, roots []string) bool {
	for _, r := range roots {
		if r != "" && (p == r || strings.HasPrefix(p, r+"/")) {
			return true
		}
	}
	return false
}
