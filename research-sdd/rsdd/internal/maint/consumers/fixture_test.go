package consumers

import (
	"bytes"
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

// fixture is a throwaway git repository, isolated from the host's git configuration and from any enclosing work
// tree (the ceiling is the parent of the temporary root).
type fixture struct {
	t    *testing.T
	root string
	dir  string
	env  []string
}

func gitDir(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not installed")
	}
	return filepath.Dir(p)
}

func envFor(t *testing.T, root, path string) []string {
	return []string{"PATH=" + path, "HOME=" + root + "/home", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_CEILING_DIRECTORIES=" + filepath.Dir(root), "GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t"}
}

func tempRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// newFixture makes an initialised repository with no commit.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := tempRoot(t)
	f := &fixture{t: t, root: root, dir: root + "/r", env: envFor(t, root, gitDir(t)+":/usr/bin:/bin")}
	for _, d := range []string{f.dir, root + "/home"} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.git("init", "-q", "-b", "main")
	return f
}

func (f *fixture) git(args ...string) {
	f.t.Helper()
	c := exec.Command("git", args...)
	c.Dir, c.Env = f.dir, f.env
	if out, err := c.CombinedOutput(); err != nil {
		f.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// write creates a file (and its directories); it stays untracked until commit.
func (f *fixture) write(rel, content string) {
	f.t.Helper()
	f.writeBytes(rel, []byte(content))
}

func (f *fixture) writeBytes(rel string, b []byte) {
	f.t.Helper()
	p := filepath.Join(f.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// commit tracks everything written so far; later writes are untracked.
func (f *fixture) commit() {
	f.t.Helper()
	f.git("add", "-A")
	f.git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "x")
}

// files writes a map of path to content.
func (f *fixture) files(m map[string]string) {
	f.t.Helper()
	for k, v := range m {
		f.write(k, v)
	}
}

func (f *fixture) run(args ...string) ran { return runIn(f.dir, f.env, args...) }

func runIn(dir string, env []string, args ...string) ran {
	var o, e bytes.Buffer
	get := func(k string) string {
		for _, kv := range env {
			if v, ok := strings.CutPrefix(kv, k+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: dir}
	rc := Run(args, s)
	return ran{o.String(), e.String(), rc}
}

// line is the first line of out that starts with prefix, or a marker when there is none.
func line(out, prefix string) string {
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, prefix) {
			return l
		}
	}
	return "<no line starting with " + prefix + ">"
}
