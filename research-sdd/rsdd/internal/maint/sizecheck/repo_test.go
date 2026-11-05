package sizecheck

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

// sysPath is the PATH of every run here: the real git, with awk for the legacy side.
const sysPath = "/usr/local/bin:/usr/bin:/bin"

// repo is a throwaway git repository under a short fixed root (tag `base` on the first commit).
type repo struct {
	t    *testing.T
	dir  string
	env  []string
	home string
}

func newRepo(t *testing.T) *repo {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "ksc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	root, _ = filepath.EvalSymlinks(root)
	r := &repo{t: t, dir: root + "/r", home: root + "/h"}
	for _, d := range []string{r.dir, r.home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r.env = []string{"PATH=" + sysPath, "HOME=" + r.home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t"}
	r.git("init", "-q", "-b", "main")
	r.git("config", "commit.gpgsign", "false")
	r.write("README", "base\n")
	r.commit("base")
	r.git("tag", "base")
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
	return string(out)
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
	r.git("commit", "-q", "-m", msg)
}

// gen is n lines that stay distinct after the hotspot normalisation (the letters differ per line).
func gen(n int, prefix string) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		s, k := "", i
		for {
			s = string(rune(97+k%26)) + s
			if k /= 26; k == 0 {
				break
			}
		}
		fmt.Fprintf(&b, "echo %s_%s done\n", prefix, s)
	}
	return b.String()
}

// churn is n lines that are ONE edit repeated (digits and quoted strings differ only).
func churn(n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "export RSDD_X%d=\"v%d\"\n", i, i)
	}
	return b.String()
}

// goRun runs the Go command in the repository.
func (r *repo) goRun(args ...string) ran {
	var o, e bytes.Buffer
	get := func(k string) string {
		for _, kv := range r.env {
			if v, ok := strings.CutPrefix(kv, k+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return r.env }, Clock: time.Now, Cwd: r.dir}
	rc := Run(args, s)
	return ran{o.String(), e.String(), rc}
}
