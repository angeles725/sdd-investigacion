package kit

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// Ports of toolbelt/tests/block-files.test.sh, nested-worktree half (kit issues #1223, #1301).

// nwFixture is mk_nw_fixture: linked worktrees (absolute and relative back-pointer, nested deep), and every
// lookalike that must NOT be a root (submodule, stray commondir, missing or foreign back-pointer, clone, the
// root's own .git file).
func nwFixture(t *testing.T) string {
	t.Helper()
	d := physical(t, t.TempDir())
	for _, dir := range []string{".claude/worktrees/agent-1", "side-wt", "sub", "clone/.git", "deep/er/wt2"} {
		if err := os.MkdirAll(filepath.Join(d, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	wt := func(name, at, backPointer string) {
		gd := d + "/.fakegit/worktrees/" + name
		write(t, gd+"/commondir", "../..\n")
		write(t, d+"/"+at+"/.git", "gitdir: "+gd+"\n")
		if backPointer != "" {
			write(t, gd+"/gitdir", backPointer+"\n")
		}
	}
	wt("side-wt", "side-wt", d+"/side-wt/.git")
	wt("wt2", "deep/er/wt2", d+"/deep/er/wt2/.git")
	wt("nobp", "nobp", "")
	wt("wrongbp", "wrongbp", d+"/side-wt/.git")
	wt("relbp", "relbp", "../../../relbp/.git")
	write(t, d+"/contrived/commondir", "")
	write(t, d+"/contrived/.git", "gitdir: .\n")
	write(t, d+"/sub/.git", "gitdir: ../.git/modules/sub\n")
	write(t, d+"/sub2/.git", "gitdir: "+d+"/.fakegit/worktrees/wtx/modules/notes\n")
	write(t, d+"/.fakegit/worktrees/wtx/modules/notes/gitdir", d+"/sub2/.git\n")
	wt("self", ".", d+"/.git")                                                    // the root's own .git FILE
	wt("agent", ".claude/worktrees/agent-1", d+"/.claude/worktrees/agent-1/.git") // pruned with its parent
	if err := os.MkdirAll(d+"/symwt", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(d+"/side-wt/.git", d+"/symwt/.git"); err != nil { // find -type f: a symlink is not a file
		t.Fatal(err)
	}
	write(t, d+"/nonl/.git", "gitdir: "+d+"/.fakegit/worktrees/nonl") // no trailing newline: still read
	write(t, d+"/.fakegit/worktrees/nonl/commondir", "")
	write(t, d+"/.fakegit/worktrees/nonl/gitdir", d+"/nonl/.git")
	write(t, d+"/prose/.git", "not a gitdir line\n")
	write(t, d+"/emptybp/.git", "gitdir: "+d+"/.fakegit/worktrees/emptybp\n")
	write(t, d+"/.fakegit/worktrees/emptybp/commondir", "")
	write(t, d+"/.fakegit/worktrees/emptybp/gitdir", "\n")
	return d
}

func TestNestedWorktreeRoots(t *testing.T) {
	d := nwFixture(t)
	roots, err := NestedWorktreeRoots(d + "/")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{d + "/.claude/worktrees", d + "/deep/er/wt2", d + "/nonl", d + "/relbp", d + "/side-wt"}
	if !slices.Equal(roots, want) {
		t.Fatalf("roots\n got %q\nwant %q", roots, want)
	}
	in := func(p string) bool { return PathInNestedWorktree(p, roots) }
	for _, p := range []string{d + "/side-wt/x-block1.md", d + "/.claude/worktrees/agent-1/x-block1.md", d + "/deep/er/wt2/a/b/x-block1.md", d + "/side-wt"} {
		if !in(p) {
			t.Errorf("%s must lie in a nested worktree", p)
		}
	}
	for _, p := range []string{d + "/x-block1.md", d + "/side-wt-old/x-block1.md", d + "/.claude/worktrees-old/x", d + "/sub/x-block1.md"} {
		if in(p) {
			t.Errorf("%s must not lie in a nested worktree", p)
		}
	}
	if PathInNestedWorktree(d+"/side-wt/x", nil) || PathInNestedWorktree("", []string{"", d}) {
		t.Error("empty roots and empty entries never match")
	}
	if !PathInNestedWorktree(d+"/c/x", []string{d + "/a", "", d + "/c"}) {
		t.Error("an empty entry must be skipped, not end the scan")
	}
}

func TestNestedWorktreeRootsCorpusInsideAWorktree(t *testing.T) {
	d := nwFixture(t)
	c := d + "/.claude/worktrees/agent-9/corpus"
	mkfiles(t, c, "keep")
	roots, err := NestedWorktreeRoots(c)
	if err != nil || PathInNestedWorktree(c+"/x-block1.md", roots) {
		t.Fatalf("a corpus that lives under .claude/worktrees is judged relative to itself: %q %v", roots, err)
	}
}

func TestNestedWorktreeRootsErrors(t *testing.T) {
	d := t.TempDir()
	_, err := NestedWorktreeRoots(d + "/missing")
	if !errors.Is(err, ErrNotDirectory) || RC(err) != 2 || err.Error() != "block-files: nested_worktree_roots: not a directory: "+d+"/missing" {
		t.Fatalf("absent root: %v rc=%d", err, RC(err))
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	mkfiles(t, d, "locked/x")
	if err := os.Chmod(d+"/locked", 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(d+"/locked", 0o755) })
	write(t, d+"/w/.git", "gitdir: "+d+"/g\n")
	write(t, d+"/g/commondir", "")
	write(t, d+"/g/gitdir", d+"/w/.git\n")
	roots, err := NestedWorktreeRoots(d)
	if !errors.Is(err, ErrIncomplete) || RC(err) != 3 || !slices.Contains(roots, d+"/w") {
		t.Fatalf("incomplete traversal keeps the partial roots and is typed: %q %v rc=%d", roots, err, RC(err))
	}
}
