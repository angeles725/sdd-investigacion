package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestBlockFileFilterEdgesAndStates(t *testing.T) {
	canon := []string{"a/x-block1.md", "retros/y-bloque22-suf_1.md", "x-block3.md"}
	noise := []string{"block12.md", "blocked-notes.md", "x-block1.txt", "x-block.md", "x-block1-.md", "dir-block1.md/file"}
	// the interesting item in FIRST, MIDDLE and LAST position, a single element, with and without a trailing newline
	cases := map[string][]string{
		"first":  {canon[0], noise[0], noise[1]},
		"middle": {noise[0], canon[1], noise[1]},
		"last":   {noise[0], noise[1], canon[2]},
		"single": {canon[0]},
	}
	for name, in := range cases {
		for _, nl := range []string{"", "\n"} {
			res := BlockFileFilter(strings.Join(in, "\n")+nl, false, "")
			want := 0
			for _, l := range in {
				if strings.Contains(strings.Join(canon, "\n"), l) {
					want++
				}
			}
			if res.Status != 0 || len(res.Lines) != want || res.Examined != len(in) {
				t.Errorf("%s nl=%q: %+v want %d lines", name, nl, res, want)
			}
		}
	}
	// -v is the exact complement
	res := BlockFileFilter(strings.Join(append(append([]string{}, canon...), noise...), "\n"), true, "")
	if !reflect.DeepEqual(res.Lines, noise) || res.Status != 0 {
		t.Errorf("-v: %+v", res)
	}
	// the three states grep distinguishes by status only: empty input and no-match are both 1, Examined tells them apart
	if r := BlockFileFilter("", false, ""); r.Status != 1 || r.Examined != 0 {
		t.Errorf("empty input: %+v", r)
	}
	if r := BlockFileFilter("notes.md\n", false, ""); r.Status != 1 || r.Examined != 1 {
		t.Errorf("no-match: %+v", r)
	}
	if r := BlockFileFilter("a-block1.md\n", true, ""); r.Status != 1 || r.Examined != 1 {
		t.Errorf("-v selecting nothing: %+v", r)
	}
}

func TestBlockFileFilterPrefixAndBadRegex(t *testing.T) {
	in := "d/ops-block1.md\nd/other-block2.md\nops-bloque3-x.md\nxops-block4.md\n"
	r := BlockFileFilter(in, false, "ops-")
	if !reflect.DeepEqual(r.Lines, []string{"d/ops-block1.md", "ops-bloque3-x.md"}) {
		t.Errorf("prefix anchor: %+v", r)
	}
	// the prefix is interpolated UNESCAPED into the ERE (kept as today): '.' is a wildcard
	if r := BlockFileFilter("axb-block1.md\n", false, "a.b-"); r.Status != 0 {
		t.Errorf("unescaped metachar: %+v", r)
	}
	// an invalid regex is grep's status 2, never a quiet 0 or 1
	if r := BlockFileFilter("a-block1.md\n", false, "("); r.Status != 2 || r.Err == nil || len(r.Lines) != 0 {
		t.Errorf("bad prefix: %+v", r)
	}
}

// mkWorktree builds a linked worktree <root>/<rel> whose .git file points at a real-looking gitdir.
func mkWorktree(t *testing.T, root, rel string) (wt, gd string) {
	t.Helper()
	wt = filepath.Join(root, rel)
	gd = filepath.Join(root, "gitdirs", strings.ReplaceAll(rel, "/", "_"))
	write(t, filepath.Join(gd, "commondir"), "../..\n")
	write(t, filepath.Join(gd, "gitdir"), filepath.Join(wt, ".git")+"\n")
	write(t, filepath.Join(wt, ".git"), "gitdir: "+gd+"\n")
	return wt, gd
}

func TestNestedWorktreeRoots(t *testing.T) {
	root := physical(t, t.TempDir())
	first, _ := mkWorktree(t, root, "a-first")
	mid, _ := mkWorktree(t, root, "m/mid")
	last, _ := mkWorktree(t, root, "z-last")
	// not worktrees: a forged commondir without the back-pointer, a submodule-style gitdir, a nested clone, a stale pointer
	forged := filepath.Join(root, "forged")
	write(t, filepath.Join(root, "gitdirs", "forged", "commondir"), "x\n")
	write(t, filepath.Join(forged, ".git"), "gitdir: "+filepath.Join(root, "gitdirs", "forged")+"\n")
	write(t, filepath.Join(root, "sub", ".git"), "gitdir: "+filepath.Join(root, "gitdirs")+"/modules/sub\n")
	write(t, filepath.Join(root, "clone", ".git", "HEAD"), "ref\n")
	write(t, filepath.Join(root, "stale", ".git"), "gitdir: /nonexistent/gd\n")
	spoofGD := filepath.Join(root, "gitdirs", "spoof") // commondir present, back-pointer names ANOTHER .git file
	write(t, filepath.Join(spoofGD, "commondir"), "x\n")
	write(t, filepath.Join(spoofGD, "gitdir"), filepath.Join(first, ".git")+"\n")
	write(t, filepath.Join(root, "spoof", ".git"), "gitdir: "+spoofGD+"\n")
	write(t, filepath.Join(root, ".git"), "gitdir: "+filepath.Join(root, "gitdirs", "a-first")+"\n") // root's own .git is never nested
	got, err := NestedWorktreeRoots(root + "/")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{root + "/.claude/worktrees", first, mid, last}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}
	// relative gitdir, resolved against the .git file's directory
	rel := filepath.Join(root, "rel")
	gd := filepath.Join(rel, "gd")
	write(t, filepath.Join(gd, "commondir"), "x\n")
	write(t, filepath.Join(gd, "gitdir"), "../.git\n") // a relative back-pointer resolves against the gitdir
	write(t, filepath.Join(rel, ".git"), "gitdir: gd\n")
	got, _ = NestedWorktreeRoots(root)
	if !contains(got, rel) {
		t.Errorf("relative gitdir not honoured: %q", got)
	}
}

func TestNestedWorktreeRootsPrunesAndTypesStates(t *testing.T) {
	root := physical(t, t.TempDir())
	// the .claude/worktrees tree is excluded wholesale and never descended
	mkWorktree(t, filepath.Join(root, ".claude/worktrees"), "inner")
	got, err := NestedWorktreeRoots(root)
	if err != nil || !reflect.DeepEqual(got, []string{root + "/.claude/worktrees"}) {
		t.Errorf("pruned tree: %q %v", got, err)
	}
	if _, err := NestedWorktreeRoots(filepath.Join(root, "nope")); !errors.Is(err, ErrNotDir) || RC(err) != 2 ||
		err.Error() != "block-files: nested_worktree_roots: not a directory: "+root+"/nope" {
		t.Errorf("absent root: %v", err)
	}
	if os.Geteuid() != 0 {
		locked := filepath.Join(root, "locked")
		write(t, filepath.Join(locked, "x"), "")
		_ = os.Chmod(locked, 0)
		defer os.Chmod(locked, 0o755)
		got, err := NestedWorktreeRoots(root)
		if !errors.Is(err, ErrIncompleteWalk) || RC(err) != 3 || len(got) == 0 ||
			err.Error() != "block-files: nested_worktree_roots: find exited 1 under "+root+" — worktrees under unreadable directories may be missing" {
			t.Errorf("incomplete walk must be typed, partial roots kept: %q %v", got, err)
		}
	}
}

func TestPathInNestedWorktree(t *testing.T) {
	roots := []string{"/r/.claude/worktrees", "/r/wt1", "/r/wt2"}
	for p, want := range map[string]bool{
		"/r/wt1": true, "/r/wt1/a/b.md": true, "/r/wt2/x": true, "/r/.claude/worktrees/q/x": true, // first, middle, last
		"/r/wt10/x": false, "/r/wt": false, "/other": false,
	} {
		if got := PathInNestedWorktree(p, roots); got != want {
			t.Errorf("%s = %v want %v", p, got, want)
		}
	}
	if PathInNestedWorktree("/r/wt1", nil) || PathInNestedWorktree("/r/wt1", []string{""}) {
		t.Error("empty roots must not match")
	}
	if !PathInNestedWorktree("/only", []string{"/only"}) {
		t.Error("single root")
	}
}
