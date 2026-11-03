//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The differential of `sweep tools`: the frozen sweep-tools.sh and sweep-tools-hook.sh (the bytes of the
// scripts before the port, sha-pinned by tools_pin_test.go; the live ones are shims now) run beside the Go
// commands in the same world. The scripts source the LIVE toolbelt/lib through a staged lib link, so the bash
// libs stay under test too. Stdout, stderr and the exit code must be equal. A missing bash FAILS: a skipped
// differential proves nothing. Rows marked nodiff are the declared differences and are not compared.

const toolsLegacyDir = "testdata/tools/legacy/"

// stageTools puts the frozen scripts in <kit>/toolbelt, with lib/ linked to the live library.
func (w *world) stageTools() {
	w.t.Helper()
	lib, err := filepath.Abs(toolbelt + "/lib")
	w.must(err)
	for _, n := range []string{"sweep-tools.sh", "sweep-tools-hook.sh"} {
		b, err := os.ReadFile(toolsLegacyDir + n)
		w.must(err)
		w.must(os.WriteFile(w.kit+"/toolbelt/"+n, b, 0o755))
	}
	if _, err := os.Lstat(w.kit + "/toolbelt/lib"); err != nil {
		w.must(os.Symlink(lib, w.kit+"/toolbelt/lib"))
	}
}

// bashTools runs a staged frozen script.
func (w *world) bashTools(script string, args ...string) result {
	w.t.Helper()
	w.stageTools()
	w.chmodUnreadable()
	cmd := exec.Command("bash", append([]string{w.kit + "/toolbelt/" + script}, args...)...)
	cmd.Dir = w.root
	cmd.Env = w.environ()
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatalf("bash %s: %v", script, err)
		}
		rc = ee.ExitCode()
	}
	return result{o.String(), e.String(), rc}
}

// chmodUnreadable makes the files of w.unreadable really unreadable for the script. As root a mode 000 file
// still reads, which would make the comparison vacuous: that FAILS instead of passing.
func (w *world) chmodUnreadable() {
	w.t.Helper()
	for _, p := range w.unreadablePaths() {
		if os.Geteuid() == 0 {
			w.t.Fatalf("running as root: mode 000 does not make %s unreadable, the differential would prove nothing", p)
		}
		w.must(os.Chmod(p, 0))
		w.t.Cleanup(func() { _ = os.Chmod(p, 0o644) })
	}
}

func (w *world) sameTools(what string, goRes, bashRes result) {
	w.t.Helper()
	if goRes != bashRes {
		w.t.Errorf("%s differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
			what, goRes.rc, goRes.out, goRes.err, bashRes.rc, bashRes.out, bashRes.err)
	}
}

func TestToolsDifferential(t *testing.T) {
	for _, sc := range toolScenarios() {
		if sc.nodiff != "" {
			continue
		}
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			sc.setup(w)
			w.sameTools("report", w.runTools(sc.args...), w.bashTools("sweep-tools.sh", sc.args...))
			w.sameTools("hook", w.runToolsHook(), w.bashTools("sweep-tools-hook.sh"))
		})
	}
}

// TestToolsDifferentialExecutable pins the tool predicate on mode: an executable of any name, and a file whose
// execute bit is set for someone else only.
func TestToolsDifferentialExecutable(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.tool(a, "run-me", true)
	w.tool(a, "plain", false)
	w.tool(a, "other-exec", false)
	w.must(os.Chmod(a+"/tools/other-exec", 0o001))
	w.tool(a, "nested/deeper/exec", true)
	w.targets(a)
	w.sameTools("report", w.runTools(), w.bashTools("sweep-tools.sh"))
}
