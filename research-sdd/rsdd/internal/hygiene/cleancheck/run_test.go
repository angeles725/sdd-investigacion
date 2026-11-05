package cleancheck

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// world is a repository, a tmp directory and a scratchpad below one temp root.
type world struct {
	t                        *testing.T
	root, repo, tmp, scratch string
	env                      []string
	out, err                 *bytes.Buffer
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, repo: root + "/repo", tmp: root + "/tmp", scratch: root + "/scratch"}
	for _, d := range []string{w.repo, w.tmp, w.scratch, root + "/home"} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w.env = gitfixture.Env([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + root + "/home", "LC_ALL=C", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null"})
	w.git("init", "-q", "-b", "main")
	w.write(w.repo+"/tracked.txt", "t\n")
	w.git("add", "tracked.txt")
	w.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
	return w
}

func (w *world) git(args ...string) {
	w.t.Helper()
	c := exec.Command("git", append([]string{"-C", w.repo}, args...)...)
	c.Env = w.env
	if out, err := c.CombinedOutput(); err != nil {
		w.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func (w *world) write(path, body string) {
	w.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// run is the command in the world: its stdout and stderr, and its exit code.
func (w *world) run(extraEnv map[string]string, args ...string) int {
	w.t.Helper()
	w.out, w.err = &bytes.Buffer{}, &bytes.Buffer{}
	env := func(k string) string { return extraEnv[k] }
	return Run(args, cli.Stdio{Out: w.out, Err: w.err, Env: env, Environ: func() []string { return w.env }, Clock: time.Now, Cwd: w.root})
}

func TestRunWritesTheEngineLinesToTheirStreams(t *testing.T) {
	w := newWorld(t)
	w.write(w.repo+"/stray.txt", "x")
	rc := w.run(nil, "--target", w.repo, "--tmp", w.tmp)
	if rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	lines := strings.Split(strings.TrimRight(w.out.String(), "\n"), "\n")
	if len(lines) != 3 || lines[0] != "ABSENT-KEEPLIST "+w.repo+"/.research-sdd/keep.txt" || lines[1] != "GARBAGE untracked stray.txt" || !strings.HasPrefix(lines[2], "CLEAN-CHECK: 1 finding(s) (untracked in "+w.repo+",") {
		t.Errorf("%q", lines)
	}
	if w.err.String() != "" {
		t.Errorf("stderr %q", w.err.String())
	}
	rc = w.run(nil, "--target", w.root+"/nope", "--tmp", w.tmp)
	if rc != 2 || w.out.String() != "" || w.err.String() != "clean-check: ERROR: target not found: "+w.root+"/nope\n" {
		t.Errorf("%d %q %q", rc, w.out.String(), w.err.String())
	}
}

func TestRunUsageAndHelp(t *testing.T) {
	w := newWorld(t)
	if rc := w.run(nil, "-h"); rc != 0 || w.out.String() != "" || w.err.String() != usageLine+"\n" {
		t.Errorf("-h: %d %q %q", rc, w.out.String(), w.err.String())
	}
	if rc := w.run(nil, "--bogus"); rc != 2 || w.out.String() != "" || w.err.String() != usageLine+"\nclean-check: ERROR: unknown argument: --bogus\n" {
		t.Errorf("--bogus: %d %q %q", rc, w.out.String(), w.err.String())
	}
	if !strings.HasPrefix(usageLine, "Usage: clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]") {
		t.Error(usageLine)
	}
}

// The environment feeds the scratchpad and the owner uid; the flag wins over the environment.
func TestRunEnvironment(t *testing.T) {
	w := newWorld(t)
	w.write(w.repo+"/.research-sdd/keep.txt", "")
	w.write(w.scratch+"/x.sh", "x")
	other := w.root + "/other"
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	args := []string{"--target", w.repo, "--tmp", w.tmp}
	if rc := w.run(map[string]string{"CLEAN_CHECK_SCRATCHPAD": w.scratch}, args...); rc != 1 || !strings.Contains(w.out.String(), "UNMANIFESTED-SCRIPT "+w.scratch+"/x.sh") {
		t.Errorf("env scratchpad: %d %q", rc, w.out.String())
	}
	if rc := w.run(map[string]string{"CLEAN_CHECK_SCRATCHPAD": w.scratch}, append(args, "--scratchpad", other)...); rc != 0 || !strings.Contains(w.out.String(), "scratchpad: 0 file(s)") {
		t.Errorf("flag over env: %d %q", rc, w.out.String())
	}
	if rc := w.run(map[string]string{"CLEAN_CHECK_UID": "x"}, args...); rc != 2 || !strings.Contains(w.err.String(), "cannot determine the owner uid ('x')") {
		t.Errorf("uid: %d %q", rc, w.err.String())
	}
	if rc := w.run(map[string]string{"CLEAN_CHECK_UID": ""}, args...); rc != 0 {
		t.Errorf("an empty uid is the current user: %d %q", rc, w.err.String())
	}
}

// Divergence: an explicit empty value is refused where the script silently fell back to a default.
func TestRunRefusesAnEmptyValue(t *testing.T) {
	w := newWorld(t)
	w.write(w.repo+"/stray.txt", "x")
	for _, flag := range []string{"--target", "--tmp", "--scratchpad", "--base", "--evidence"} {
		rc := w.run(nil, flag, "")
		if rc != 2 || w.out.String() != "" || !strings.HasSuffix(w.err.String(), "clean-check: ERROR: "+flag+" needs a non-empty value\n") {
			t.Errorf("%s: %d %q %q", flag, rc, w.out.String(), w.err.String())
		}
	}
}
