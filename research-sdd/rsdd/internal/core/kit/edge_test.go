package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// R3-nwroots-slash-root: a root of "/" must be walked from "/", never from "" (the old TrimSuffix made it empty,
// so the probe failed with "find exited 1 under  —" and joined paths as "//x"). The walk itself is injected so the
// test never touches the real filesystem root.
func TestNestedWorktreeRootsSlashRootWalksFromSlash(t *testing.T) {
	tmp := t.TempDir()
	if err := os.MkdirAll(filepath.Join(tmp, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	var calls []string
	readDir := func(p string) ([]os.DirEntry, error) {
		calls = append(calls, p)
		if p == "" {
			return nil, os.ErrNotExist // what the real os.ReadDir("") does
		}
		return os.ReadDir(tmp + p)
	}
	got, err := nestedWorktreeRoots("/", readDir)
	if err != nil {
		t.Fatalf("a real directory root must not be an incomplete walk: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"/.claude/worktrees"}) {
		t.Errorf("roots = %q", got)
	}
	if !reflect.DeepEqual(calls, []string{"/", "/d"}) {
		t.Errorf("readDir calls = %q, want the walk to start at \"/\" and join without a double slash", calls)
	}
}

func TestOwnGitOfTheProbeRoot(t *testing.T) {
	for _, c := range []struct {
		wt, root string
		want     bool
	}{{"/r", "/r", true}, {"/r/a", "/r", false}, {"", "/", true}, {"/a", "/", false}, {"r/", "r/", true}, {"r", "r/", false}} {
		if got := ownGit(c.wt, c.root); got != c.want {
			t.Errorf("ownGit(%q, %q) = %v", c.wt, c.root, got)
		}
	}
}

// Trailing-slash roots are compared with bash. `${_root%/}` strips ONE slash, and find prints children of "root/"
// as "root/child" (no doubled slash), so "root//" keeps its own quirks: pinned by the differential, not by hand.
func TestDifferentialNestedWorktreeTrailingSlashRoots(t *testing.T) {
	root := physical(t, t.TempDir())
	mkWorktree(t, root, "a-first")
	mkWorktree(t, root, "m/mid")
	for _, r := range []string{root, root + "/", root + "//", root + "///"} {
		b := bashDriver(t, env0(), "", "nwroots", r)
		got, err := NestedWorktreeRoots(r)
		goErr := ""
		if err != nil {
			goErr = err.Error() + "\n"
		}
		expectSame(t, "nwroots-trailing "+r, render(RC(err), sortedAfterFirst(got)+goErr), render(b.rc, bashRoots(b.stdout)+b.stderr))
	}
}

func TestDifferentialPathInSlashRoot(t *testing.T) {
	for _, p := range []string{"/", "/x", "/x/y", "", "x"} {
		for _, rs := range [][]string{{"/"}, {"/", "/x"}, {"//"}} {
			b := bashDriver(t, env0(), "", "pathin", p, joinNL(rs))
			got := 1
			if PathInNestedWorktree(p, rs) {
				got = 0
			}
			expectSame(t, "pathin-slash "+p+" "+joinNL(rs), render(got, ""), render(b.rc, b.stdout))
		}
	}
}

func joinNL(xs []string) string {
	s := ""
	for i, x := range xs {
		if i > 0 {
			s += "\n"
		}
		s += x
	}
	return s
}

// R3-gfm-start-dir-listed: the START directory is matched like any entry, so one named like a state file was
// listed even under GFMShaped (the type filter was applied to its children only).
func TestStartDirNamedLikeStateFileFollowsTheQuirk(t *testing.T) {
	start := filepath.Join(t.TempDir(), "RESEARCH-STATE-x.md")
	mkfiles(t, start, "RESEARCH-STATE.md")
	list := func() []string {
		got, err := ListStateFiles(start)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	// legacy bash lists the directory itself and the file inside; this is also compared with bash below
	if got := list(); !reflect.DeepEqual(got, []string{start, start + "/RESEARCH-STATE.md"}) {
		t.Fatalf("legacy: %q", got)
	}
	withBehaviour(t, GFMShaped)
	if got := list(); !reflect.DeepEqual(got, []string{start + "/RESEARCH-STATE.md"}) {
		t.Fatalf("gfm-shaped must list only the file inside, got %q", got)
	}
	if got, err := ResolveStateFile(start, ResolveOptions{}); err != nil || got != start+"/RESEARCH-STATE.md" {
		t.Fatalf("resolve under gfm-shaped: %q %v", got, err)
	}
}

func TestDifferentialStartDirNamedLikeStateFile(t *testing.T) {
	start := filepath.Join(t.TempDir(), "RESEARCH-STATE-x.md")
	mkfiles(t, start, "RESEARCH-STATE.md")
	b := bashDriver(t, env0(), "", "liststate", start)
	got, err := ListStateFiles(start)
	if err != nil {
		t.Fatal(err)
	}
	expectSame(t, "liststate-start-dir-named-like-state", lines(got), b.stdout)
	rb := bashDriver(t, env0(), "", "resolvestate", start)
	rg, rerr := ResolveStateFile(start, ResolveOptions{})
	expectSame(t, "resolvestate-start-dir-named-like-state", render(RC(rerr), rg+nl(rg)), render(rb.rc, rb.stdout))
	if errors.Is(rerr, ErrStateUsage) {
		t.Fatal("start dir is a directory")
	}
}
