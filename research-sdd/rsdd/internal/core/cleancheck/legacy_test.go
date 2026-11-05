//go:build !nodiff

package cleancheck

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// legacyDir stages the frozen script with its lib beside it.
func legacyDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	for _, f := range []string{"clean-check.sh", "lib/scripts-manifest.sh"} {
		b, err := os.ReadFile("testdata/legacy/" + f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(d, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, f), b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return d
}

type ran struct {
	merged, out, err string
	rc               int
}

// runLegacy runs the frozen script in the world with stdout and stderr on ONE pipe (so the order is the print order)
// and again on two, which is the same run only for the split streams.
func (w *world) runLegacy(stage string, extraEnv []string, args ...string) ran {
	w.t.Helper()
	run := func(stdout, stderr *bytes.Buffer) int {
		c := exec.Command("bash", append([]string{stage + "/clean-check.sh"}, args...)...)
		c.Dir, c.Env = w.root, append(append([]string(nil), w.env...), extraEnv...)
		c.Stdout, c.Stderr = stdout, stderr
		if err := c.Run(); err != nil {
			ee, ok := err.(*exec.ExitError)
			if !ok {
				w.t.Fatal(err)
			}
			return ee.ExitCode()
		}
		return 0
	}
	var m bytes.Buffer
	rc := run(&m, &m)
	var o, e bytes.Buffer
	run(&o, &e)
	return ran{merged: m.String(), out: o.String(), err: e.String(), rc: rc}
}
