package kitworld

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Stage copies the frozen legacy scripts of a differential test (src/<name> for each name) into a fresh directory,
// executable, and returns it. The frozen oracle never changes, so a later port of a script it sources cannot move it.
func Stage(t *testing.T, src string, names ...string) string {
	t.Helper()
	stage := t.TempDir()
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(src, n))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, n), b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return stage
}

// Ran is one finished child process.
type Ran struct {
	Out, Err string
	RC       int
}

// RunBash runs `bash script args...` in dir with exactly env, and reports its stdout, stderr and exit code. A child
// that cannot be started at all is a test failure, never a result.
func RunBash(t *testing.T, dir string, env []string, script string, args ...string) Ran {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	c := exec.Command(bash, append([]string{script}, args...)...)
	c.Dir, c.Env = dir, env
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
	return Ran{o.String(), e.String(), rc}
}
