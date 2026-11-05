//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"os"
	"os/exec"
	"testing"
)

// The differential of `sweep all`: the frozen sweep-all.sh (the bytes of the script before the port, sha-pinned
// by all_pin_test.go; the live one is a shim now) runs beside the Go command in the same world. It is staged
// next to the stub scripts, where it finds its toolbelt. Stdout, stderr and the exit code must be equal. A
// missing bash FAILS: a skipped differential proves nothing.

const allLegacyDir = "testdata/all/legacy/"

// bashAll runs the staged frozen script.
func (w *world) bashAll() result {
	w.t.Helper()
	b, err := os.ReadFile(allLegacyDir + "sweep-all.sh")
	w.must(err)
	w.must(os.WriteFile(w.kit+"/toolbelt/sweep-all.sh", b, 0o755))
	cmd := exec.Command("bash", w.kit+"/toolbelt/sweep-all.sh")
	cmd.Dir = w.root
	cmd.Env = w.environ()
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatalf("bash sweep-all.sh: %v", err)
		}
		rc = ee.ExitCode()
	}
	return result{o.String(), e.String(), rc}
}

func TestAllDifferential(t *testing.T) {
	for _, sc := range allScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			sc.setup(w)
			goRes, bashRes := w.runAll(), w.bashAll()
			if goRes != bashRes {
				t.Errorf("differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
					goRes.rc, goRes.out, goRes.err, bashRes.rc, bashRes.out, bashRes.err)
			}
		})
	}
}
