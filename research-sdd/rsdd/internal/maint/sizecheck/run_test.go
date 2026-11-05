package sizecheck

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// onlyGit gives the repo a PATH that holds the real git and nothing else (no awk, no mktemp).
func onlyGit(t *testing.T, r *repo) {
	t.Helper()
	bin := r.home + "/bin"
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	g, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(g, bin+"/git"); err != nil {
		t.Fatal(err)
	}
	r.env[0] = "PATH=" + bin
}

func TestAwkAndMktempAreNoLongerDependencies(t *testing.T) {
	r := newRepo(t)
	r.write("a.txt", gen(3, "a"))
	r.commit("c")
	onlyGit(t, r)
	got := r.goRun("--base", "base")
	if got.rc != 0 || !strings.HasSuffix(got.out, "size: ok\n") || got.err != "" {
		t.Errorf("%+v", got)
	}
}

func TestGitMissingIsATypedDegradedState(t *testing.T) {
	r := newRepo(t)
	r.env[0] = "PATH=" + r.home + "/empty"
	for _, c := range []struct {
		args []string
		out  string
	}{
		{[]string{"--base", "base"}, "size: degraded\n"},
		{[]string{"--base", "base", "--format", "json"}, "{\"state\":\"degraded\",\"reason\":\"git is not installed\"}\n"},
	} {
		got := r.goRun(c.args...)
		if got.rc != 2 || got.out != c.out || got.err != "degraded: kit-size-check: git is not installed\n" {
			t.Errorf("%v: %+v", c.args, got)
		}
	}
}

func TestNotAWorkTree(t *testing.T) {
	r := newRepo(t)
	r.dir = r.home // a directory that is no repository
	got := r.goRun("--base", "base")
	if got.rc != 2 || got.out != "size: degraded\n" || got.err != "degraded: kit-size-check: not inside a git work tree\n" {
		t.Errorf("%+v", got)
	}
}

func TestVerdictExitCodesAndHelp(t *testing.T) {
	r := newRepo(t)
	r.write("a.txt", gen(11, "a"))
	r.commit("c")
	for args, rc := range map[string]int{"--budget 10": 0, "--budget 10 --strict": 3, "--budget 5": 3, "--budget 5 --strict": 3, "--budget 11": 0} {
		if got := r.goRun(append([]string{"--base", "base"}, strings.Fields(args)...)...); got.rc != rc {
			t.Errorf("%s: rc %d, want %d\n%s", args, got.rc, rc, got.out)
		}
	}
	h := r.goRun("--help")
	if h.rc != 0 || h.out != help || !strings.HasPrefix(h.out, "kit-size-check.sh — pre-RDD size guard") {
		t.Errorf("%+v", h)
	}
	// an unknown argument prints the usage on stderr before the typed state
	u := r.goRun("--bogus")
	if u.rc != 2 || u.err != help+"degraded: kit-size-check: unknown argument: --bogus\n" || u.out != "size: degraded\n" {
		t.Errorf("%+v", u)
	}
	// read-only: the repository is untouched
	if st := r.git("status", "--porcelain"); st != "" {
		t.Errorf("status: %q", st)
	}
}
