//go:build unix

package git

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

// Differential test: the git calls of research-sdd-status.sh and merge-gate.sh, copied verbatim into
// testdata/git-driver.sh, and the core/git questions must read the same value and return code from the same real
// repository and environment. It takes ~0.1 s, so unlike the slow differentials it is not behind the nodiff tag
// and gremlins runs it too. A missing bash or git FAILS: a skipped parity test proves nothing.

func runGitDriver(t *testing.T, f fixture, dir, q string, args ...string) string {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required for the differential test: %v", err)
	}
	driver, _ := filepath.Abs("testdata/git-driver.sh")
	cmd := exec.Command(bash, append([]string{driver, q, dir}, args...)...)
	cmd.Env = f.r.Env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver failure (a git rc is printed, never the driver's exit): %v: %s", err, stderr.String())
	}
	return stdout.String()
}

// askPort answers like the driver: rc (0, 1 for "no", the git exit code on an *ExitError) and the value.
func askPort(t *testing.T, f fixture, dir, q string, args ...string) string {
	t.Helper()
	var v string
	var ok = true
	var err error
	switch q {
	case "remotes":
		names, _ := f.r.Remotes(dir) // status reads a failed `git remote` as no remote
		out := "rc=0\n"
		for _, n := range names {
			out += "v=" + n + "\n"
		}
		return out
	case "url":
		v, err = f.r.RemoteURL(dir, args[0])
	case "commit":
		v, ok, err = f.r.ResolveCommit(dir, args[0])
	case "mb":
		v, ok, err = f.r.MergeBase(dir, args[0], args[1])
	case "anc":
		ok, err = f.r.IsAncestor(dir, args[0], args[1])
	case "count":
		var n int
		if n, err = f.r.CountRange(dir, args[0]); err == nil {
			v = strconv.Itoa(n)
		}
	default:
		t.Fatalf("unknown question %s", q)
	}
	rc := 0
	var ee *ExitError
	switch {
	case errors.As(err, &ee):
		rc = ee.Code
	case err != nil:
		t.Fatalf("untyped failure: %v", err)
	case !ok:
		rc = 1
	}
	return fmt.Sprintf("rc=%d\nv=%s\n", rc, v)
}

func TestDifferentialWithInlineGitCalls(t *testing.T) {
	f := newFixture(t)
	out := t.TempDir() // not a repository
	cases := []struct {
		dir, q string
		args   []string
	}{
		{f.dir, "remotes", nil}, {out, "remotes", nil},
		{f.dir, "url", []string{"origin"}}, {f.dir, "url", []string{"upstream"}}, {f.dir, "url", []string{"absent"}},
		{out, "url", []string{"origin"}},
		{f.dir, "commit", []string{"HEAD"}}, {f.dir, "commit", []string{f.c1[:12]}}, {f.dir, "commit", []string{"side"}},
		{f.dir, "commit", []string{"nope"}}, {f.dir, "commit", []string{f.t1}}, {out, "commit", []string{"HEAD"}},
		{f.dir, "mb", []string{"HEAD", "side"}}, {f.dir, "mb", []string{"HEAD", "orphan"}}, {f.dir, "mb", []string{"HEAD", "nope"}},
		{f.dir, "anc", []string{f.c1, "main"}}, {f.dir, "anc", []string{"main", "main"}}, {f.dir, "anc", []string{"side", "main"}},
		{f.dir, "anc", []string{"orphan", "main"}}, {f.dir, "anc", []string{"nope", "main"}},
		{f.dir, "count", []string{f.c1 + "..HEAD"}}, {f.dir, "count", []string{"HEAD..HEAD"}}, {f.dir, "count", []string{"orphan..HEAD"}},
		{f.dir, "count", []string{"nope..HEAD"}}, {out, "count", []string{"a..b"}},
	}
	for _, c := range cases {
		name := fmt.Sprintf("%s %v in %s", c.q, c.args, filepath.Base(c.dir))
		t.Run(name, func(t *testing.T) {
			bash, port := runGitDriver(t, f, c.dir, c.q, c.args...), askPort(t, f, c.dir, c.q, c.args...)
			if bash != port {
				t.Fatalf("bash:\n%s\ngo:\n%s", bash, port)
			}
		})
	}
}
