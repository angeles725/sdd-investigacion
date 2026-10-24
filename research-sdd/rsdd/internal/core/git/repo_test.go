//go:build unix

package git

import (
	"errors"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// fixture is a real repository: main has c1 <- c2, side branches from c1 (s1), orphan is an unrelated root (o1);
// remotes origin and upstream. Git runs with no system or global config and nothing but its own directory on PATH.
type fixture struct {
	dir                string
	r                  Runner
	c1, c2, s1, o1, t1 string // t1 is c2's tree
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Fatalf("git is required: %v", err)
	}
	home := t.TempDir()
	f := fixture{dir: filepath.Join(home, "repo"), r: Runner{Bin: bin, Env: []string{
		"PATH=" + filepath.Dir(bin), "HOME=" + home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "LC_ALL=C",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid",
	}}}
	git := func(args ...string) string {
		t.Helper()
		out, err := f.r.Run(f.dir, args...)
		if err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
		return strings.TrimSpace(string(out))
	}
	if _, err := f.r.Run(home, "init", "-q", "-b", "main", f.dir); err != nil {
		t.Fatal(err)
	}
	commit := func(msg string) string {
		git("commit", "-q", "--allow-empty", "-m", msg)
		return git("rev-parse", "HEAD")
	}
	f.c1 = commit("c1")
	f.c2 = commit("c2")
	f.t1 = git("rev-parse", "HEAD^{tree}")
	git("checkout", "-q", "-b", "side", f.c1)
	f.s1 = commit("s1")
	git("checkout", "-q", "--orphan", "orphan")
	f.o1 = commit("o1")
	git("checkout", "-q", "main")
	git("remote", "add", "origin", "https://github.com/o/r.git")
	git("remote", "add", "upstream", "git@github.com:u/r")
	return f
}

func exitCode(err error) int {
	var ee *ExitError
	if errors.As(err, &ee) {
		return ee.Code
	}
	return -1
}

func TestRemotes(t *testing.T) {
	f := newFixture(t)
	got, err := f.r.Remotes(f.dir)
	if err != nil || !slices.Equal(got, []string{"origin", "upstream"}) {
		t.Fatalf("got %q, %v", got, err)
	}
	if got, err := f.r.Remotes(t.TempDir()); exitCode(err) != 128 || got != nil {
		t.Fatalf("outside a repo: %q, %v", got, err)
	}
	for _, c := range []struct {
		out  string
		want []string
	}{{"", nil}, {"a", []string{"a"}}, {"a\n\nb\n", []string{"a", "", "b"}}, {"a\n\n", []string{"a", ""}}} {
		if got, err := stub(t, "GIT_OUT="+c.out).Remotes(""); err != nil || !slices.Equal(got, c.want) {
			t.Errorf("mapfile of %q: %q, %v", c.out, got, err)
		}
	}
}

func TestRemoteURL(t *testing.T) {
	f := newFixture(t)
	if got, err := f.r.RemoteURL(f.dir, "upstream"); err != nil || got != "git@github.com:u/r" {
		t.Fatalf("got %q, %v", got, err)
	}
	if got, err := f.r.RemoteURL(f.dir, "absent"); exitCode(err) != 2 || got != "" {
		t.Fatalf("absent remote: %q, %v", got, err)
	}
	if got, err := stub(t, `GIT_OUT=u\n\n`).RemoteURL("", "x"); err != nil || got != "u" {
		t.Fatalf("trailing newlines: %q, %v", got, err)
	}
}

func TestResolveCommit(t *testing.T) {
	f := newFixture(t)
	for _, c := range []struct {
		rev, sha string
		ok       bool
	}{{"HEAD", f.c2, true}, {f.c1[:12], f.c1, true}, {"side", f.s1, true}, {"nope", "", false}, {f.t1, "", false}} {
		if sha, ok, err := f.r.ResolveCommit(f.dir, c.rev); err != nil || sha != c.sha || ok != c.ok {
			t.Errorf("%s: %q %v %v, want %q %v", c.rev, sha, ok, err, c.sha, c.ok)
		}
	}
	if _, ok, err := f.r.ResolveCommit(t.TempDir(), "HEAD"); exitCode(err) != 128 || ok {
		t.Fatalf("outside a repo: %v %v", ok, err)
	}
}

func TestMergeBase(t *testing.T) {
	f := newFixture(t)
	if mb, ok, err := f.r.MergeBase(f.dir, "main", "side"); err != nil || !ok || mb != f.c1 {
		t.Fatalf("main/side: %q %v %v", mb, ok, err)
	}
	if mb, ok, err := f.r.MergeBase(f.dir, "main", "orphan"); err != nil || ok || mb != "" {
		t.Fatalf("unrelated: %q %v %v", mb, ok, err)
	}
	if _, ok, err := f.r.MergeBase(f.dir, "main", "nope"); exitCode(err) != 128 || ok {
		t.Fatalf("bad rev: %v %v", ok, err)
	}
}

func TestIsAncestor(t *testing.T) {
	f := newFixture(t)
	for _, c := range []struct {
		a, b string
		want bool
	}{{f.c1, "main", true}, {"main", "main", true}, {"side", "main", false}, {"orphan", "main", false}} {
		if got, err := f.r.IsAncestor(f.dir, c.a, c.b); err != nil || got != c.want {
			t.Errorf("%s %s: %v %v", c.a, c.b, got, err)
		}
	}
	if got, err := f.r.IsAncestor(f.dir, "nope", "main"); exitCode(err) != 128 || got {
		t.Fatalf("bad rev: %v %v", got, err)
	}
}

func TestCountRange(t *testing.T) {
	f := newFixture(t)
	if n, err := f.r.CountRange(f.dir, f.c1+"..main"); err != nil || n != 1 {
		t.Fatalf("got %d, %v", n, err)
	}
	if n, err := f.r.CountRange(f.dir, "main..main"); err != nil || n != 0 {
		t.Fatalf("empty range: %d, %v", n, err)
	}
	if _, err := f.r.CountRange(f.dir, "nope..main"); exitCode(err) != 128 {
		t.Fatalf("bad range: %v", err)
	}
	for _, out := range []string{"", "x", "-1", "+1", "1 2"} {
		if _, err := stub(t, "GIT_OUT="+out+"\n").CountRange("", "a..b"); !errors.Is(err, ErrUnexpectedOutput) {
			t.Errorf("output %q: %v", out, err)
		}
	}
}
