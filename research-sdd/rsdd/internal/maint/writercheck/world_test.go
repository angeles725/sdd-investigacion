package writercheck

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
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The fixture world of this package's tests: a small pristine git repository holding a miniature kit (fake suites,
// scripts that name each other, impact manifests), cloned once per case. Commit dates are fixed, so two clones that
// receive the same edits get the same commit ids and a legacy-versus-Go comparison sees identical repositories.

const (
	sysPath = "/usr/local/bin:/usr/bin:/bin"
	tb      = "research-sdd/toolbelt"
	ts      = tb + "/tests"
	pfx     = ts + "/"
)

var pristine string // the pristine repository, built by TestMain

func TestMain(m *testing.M) {
	root, err := os.MkdirTemp("", "wckp")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	root, _ = filepath.EvalSymlinks(root)
	pristine = root + "/pristine"
	if err := buildPristine(pristine, root); err != nil {
		fmt.Fprintln(os.Stderr, "pristine:", err)
		os.RemoveAll(root)
		os.Exit(2)
	}
	code := m.Run()
	os.RemoveAll(root)
	os.Exit(code)
}

// baseEnv is the environment of every child: a PATH of system tools only, no user git configuration, fixed dates.
func baseEnv(home string) []string {
	d := "2026-01-02T03:04:05+0000"
	return []string{"PATH=" + sysPath, "HOME=" + home, "TMPDIR=" + home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0", "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		"GIT_AUTHOR_DATE=" + d, "GIT_COMMITTER_DATE=" + d}
}

func gitIn(dir string, env []string, args ...string) (string, error) {
	c := exec.Command("git", args...)
	c.Dir, c.Env = dir, env
	out, err := c.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("git %v: %v\n%s", args, err, out)
	}
	return string(out), nil
}

func buildPristine(dir, root string) error {
	env := baseEnv(root)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for rel, body := range pristineFiles() {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			return err
		}
	}
	for _, a := range [][]string{{"init", "-q", "-b", "main"}, {"config", "commit.gpgsign", "false"}, {"add", "-A"},
		{"commit", "-q", "-m", "base"}, {"tag", "base"}} {
		if _, err := gitIn(dir, env, a...); err != nil {
			return err
		}
	}
	return nil
}

// kase is one case: a clone of the pristine repository inside its own root directory.
type kase struct {
	t    *testing.T
	root string // the case root: the clone, the log directories and the scratch live below it
	dir  string // the clone
	env  []string
	// impact is the suite-impact.sh both sides run.
	impact string
}

func newKase(t *testing.T) *kase {
	t.Helper()
	root, err := os.MkdirTemp("", "wck")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	root, _ = filepath.EvalSymlinks(root)
	k := &kase{t: t, root: root, dir: root + "/r", env: baseEnv(root), impact: impactScript(t)}
	k.rootGit("clone", "-q", pristine, k.dir)
	return k
}

func (k *kase) rootGit(args ...string) string {
	k.t.Helper()
	out, err := gitIn(k.root, k.env, args...)
	if err != nil {
		k.t.Fatal(err)
	}
	return out
}

func (k *kase) git(args ...string) string {
	k.t.Helper()
	out, err := gitIn(k.dir, k.env, args...)
	if err != nil {
		k.t.Fatal(err)
	}
	return out
}

func (k *kase) write(rel, body string) {
	k.t.Helper()
	p := filepath.Join(k.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		k.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		k.t.Fatal(err)
	}
}

// add appends body to rel (creating it).
func (k *kase) add(rel, body string) {
	k.t.Helper()
	old := ""
	if b, err := os.ReadFile(filepath.Join(k.dir, rel)); err == nil {
		old = string(b)
	}
	k.write(rel, old+body)
}

func (k *kase) commit(msg string) {
	k.t.Helper()
	k.git("add", "-A")
	k.git("commit", "-q", "-m", msg)
}

// touch appends a comment line to each file and commits.
func (k *kase) touch(files ...string) {
	k.t.Helper()
	for _, f := range files {
		k.add(f, "# changed\n")
	}
	k.commit("change")
}

// ran is one finished run.
type ran struct {
	out, err string
	rc       int
}

// goRun runs the command with the case environment (plus extra) from the case root.
func (k *kase) goRun(extra []string, args ...string) ran {
	env := append(append([]string(nil), k.env...), extra...)
	get := func(key string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, key+"="); ok {
				v = s
			}
		}
		return v
	}
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: k.root}
	rc := Run(args, s)
	return ran{o.String(), e.String(), rc}
}

// impactScript is the real suite-impact.sh of this kit, which both sides run.
func impactScript(t *testing.T) string {
	return kitroot.Path(t, "toolbelt", "tests", "suite-impact.sh")
}

// norm replaces the case root by <R>, so two runs in different roots compare equal.
func (k *kase) norm(s string) string { return strings.ReplaceAll(s, k.root, "<R>") }
