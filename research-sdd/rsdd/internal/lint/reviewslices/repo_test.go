package reviewslices

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// ran is one run: stdout, stderr and the exit code.
type ran struct {
	out, err string
	rc       int
}

// sysPath is the PATH of every run here: the real git and awk (the legacy script needs awk).
const sysPath = "/usr/local/bin:/usr/bin:/bin"

// fixedDate makes every commit reproducible: the same builder gives the same shas on every machine and run, which
// is what lets a golden carry them.
const fixedDate = "2000-01-01T00:00:00+0000"

// repo is a throwaway git repository under a fresh temp root (tag `base` on the first commit). Both sides of a
// differential run read the SAME repository: the tool is report-only, which the scenarios also assert.
type repo struct {
	t    *testing.T
	root string // temp root: <root>/r is the repository, <root>/plain a directory outside any repository
	dir  string
	env  []string
	// shims maps a shimmed scenario to the directory of its git wrapper (writeShims).
	shims map[string]string
}

// newRepo is a root with a repository in it; newRoot is the same root with a plain directory <root>/r instead (for
// the scenarios that end before git is asked anything: a usage error, a bad --cwd).
func newRepo(t *testing.T) *repo { return newWorld(t, true) }

func newRoot(t *testing.T) *repo { return newWorld(t, false) }

func newWorld(t *testing.T, withRepo bool) *repo {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := &repo{t: t, root: root, dir: root + "/r"}
	for _, d := range []string{r.dir, root + "/plain", root + "/home"} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r.env = []string{"PATH=" + sysPath, "HOME=" + root + "/home", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0", "GIT_CEILING_DIRECTORIES=" + root,
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		"GIT_AUTHOR_DATE=" + fixedDate, "GIT_COMMITTER_DATE=" + fixedDate}
	r.write("seed.txt", "seed\n")
	if withRepo {
		r.git("init", "-q", "-b", "main")
		r.git("config", "commit.gpgsign", "false")
		r.commit("base")
		r.git("tag", "base")
	}
	return r
}

func (r *repo) git(args ...string) string {
	r.t.Helper()
	c := exec.Command("git", args...)
	c.Dir, c.Env = r.dir, r.env
	out, err := c.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimRight(string(out), "\n")
}

func (r *repo) write(rel, content string) {
	r.t.Helper()
	p := filepath.Join(r.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

func (r *repo) commit(msg string) {
	r.t.Helper()
	r.git("add", "-A")
	r.git("commit", "-q", "--allow-empty", "-m", msg)
}

// lines is n lines `<prefix>-1` .. `<prefix>-n`: a commit that creates the file counts n authored lines.
func lines(prefix string, n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "%s-%d\n", prefix, i)
	}
	return b.String()
}

// add is a commit that creates file f with n lines.
func (r *repo) add(f string, n int) {
	r.t.Helper()
	r.write(f, lines(f, n))
	r.commit(fmt.Sprintf("add %s %d", f, n))
}

// expand fills the placeholders of an argument, a path or a shim body: {R} the repository, {ROOT} the temp root.
func (r *repo) expand(s string) string {
	return strings.NewReplacer("{R}", r.dir, "{ROOT}", r.root).Replace(s)
}

// writeShims writes the `git` wrapper of every shimmed scenario into its own directory (the scenario puts that
// directory first on PATH): `case "$*" in <body> esac`, then the real git. Both sides call `git -C <dir> <args>`; the
// case words see only <args> (`rev-list --parents ...`), so a pattern never matches the temp path. The wrappers are
// written BEFORE any parallel work starts: writing an executable while another goroutine forks can leave the fork
// holding the write descriptor, and the next exec of that file fails with ETXTBSY.
func writeShims(t *testing.T, scs []scenario) map[string]string {
	t.Helper()
	real, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	dirs := map[string]string{}
	for _, sc := range scs {
		if sc.gitOnly {
			dir := root + "/gitonly-" + sc.name
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(real, dir+"/git"); err != nil {
				t.Fatal(err)
			}
			dirs[sc.name] = dir
		}
		if sc.shim == "" {
			continue
		}
		dir := root + "/" + sc.name
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		text := "#!/bin/sh\nD=\"$2\"\nshift 2\ncase \"$*\" in\n" + sc.shim + "\nesac\nexec " + real + " -C \"$D\" \"$@\"\n"
		if err := os.WriteFile(dir+"/git", []byte(text), 0o755); err != nil {
			t.Fatal(err)
		}
		dirs[sc.name] = dir
	}
	return dirs
}

// goRun runs the Go command from dir (the working directory of the process the script would have run in).
func (r *repo) goRun(dir string, extraEnv []string, args ...string) ran {
	env := append(append([]string(nil), r.env...), extraEnv...)
	get := func(k string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, k+"="); ok {
				v = s
			}
		}
		return v
	}
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: dir}
	rc := Run(args, s)
	return ran{o.String(), e.String(), rc}
}

// bashRun runs the frozen legacy script from dir with the same environment.
func (r *repo) bashRun(t *testing.T, script, dir string, extraEnv []string, args ...string) ran {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required: a skipped differential proves nothing: %v", err)
	}
	c := exec.Command(bash, append([]string{script}, args...)...)
	c.Dir, c.Env = dir, append(append([]string(nil), r.env...), extraEnv...)
	var o, e bytes.Buffer
	c.Stdout, c.Stderr = &o, &e
	rc := 0
	if err := c.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("cannot run %s: %v", script, err)
		}
		rc = ee.ExitCode()
	}
	return ran{o.String(), e.String(), rc}
}

// state is what a report-only run must leave alone.
func (r *repo) state() string {
	if _, err := os.Stat(r.dir + "/.git"); err != nil {
		return "" // a plain root: nothing for git to report
	}
	return r.git("for-each-ref") + "\n" + r.git("status", "--porcelain", "-uall") + "\n" + r.git("rev-parse", "HEAD")
}

func symlink(target, link string) error { return os.Symlink(target, link) }

func orDir(cwd, dir string) string {
	if cwd == "" {
		return dir
	}
	return cwd
}

// runEnv is the scenario's extra environment for one side of the run (CNT is a counter file private to the side).
func (r *repo) runEnv(sc scenario, side string) []string {
	env := []string{"CNT=" + r.root + "/cnt-" + sc.name + "-" + side}
	if sc.shim != "" {
		env = append(env, "PATH="+r.shims[sc.name]+":"+sysPath)
	}
	if sc.gitOnly {
		env = append(env, "PATH="+r.shims[sc.name]) // the real git and nothing else: no awk
	}
	if sc.target > 0 {
		shas := strings.Fields(r.git("rev-list", "--first-parent", "--reverse", "base..HEAD"))
		env = append(env, "TARGET="+shas[sc.target-1])
		if sc.target < len(shas) {
			env = append(env, "NEXT="+shas[sc.target])
		}
	}
	for _, e := range sc.env {
		env = append(env, r.expand(e))
	}
	return env
}

func (r *repo) expandAll(in []string) []string {
	out := make([]string, len(in))
	for i, a := range in {
		out[i] = r.expand(a)
	}
	return out
}

// expandC1 fills {C1}, the 12-character sha of the first commit after the tag `base`, and {B}, that of `base`.
func (r *repo) expandC1(s string) string {
	if strings.Contains(s, "{C1}") {
		first, _, _ := strings.Cut(r.git("rev-list", "--reverse", "base..HEAD"), "\n")
		s = strings.ReplaceAll(s, "{C1}", r.git("rev-parse", "--short=12", first))
	}
	return strings.ReplaceAll(s, "{B}", r.git("rev-parse", "--short=12", "base"))
}
