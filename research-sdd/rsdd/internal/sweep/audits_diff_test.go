//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

// The differential of `sweep audits`: the frozen sweep-audits.sh and sweep-audits-hook.sh (the bytes of the
// scripts before the port, sha-pinned by audits_pin_test.go; the live ones are shims now) run beside the Go
// commands in the same world. The scripts source the LIVE toolbelt/lib through a staged lib link, so the bash
// libs stay under test too. Stdout, stderr and the exit code must be equal. A missing bash, git or jq FAILS: a
// skipped differential proves nothing. Fixtures keep hours or days of margin around every threshold because the
// script reads the real clock a few seconds after the world was built.

const auditsLegacyDir = "testdata/audits/legacy/"

// stageAudits puts the frozen scripts in <kit>/toolbelt, with lib/ linked to the live library.
func (w *world) stageAudits() {
	w.t.Helper()
	lib, err := filepath.Abs(toolbelt + "/lib")
	w.must(err)
	for _, n := range []string{"sweep-audits.sh", "sweep-audits-hook.sh"} {
		b, err := os.ReadFile(auditsLegacyDir + n)
		w.must(err)
		w.must(os.WriteFile(w.kit+"/toolbelt/"+n, b, 0o755))
	}
	if _, err := os.Lstat(w.kit + "/toolbelt/lib"); err != nil {
		w.must(os.Symlink(lib, w.kit+"/toolbelt/lib"))
	}
}

// bashAudits runs a staged frozen script.
func (w *world) bashAudits(script string, args ...string) result {
	w.t.Helper()
	w.stageAudits()
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

// reBashTestErr is the diagnostic of `[ abc -gt 7 ]` in the frozen script: it names the script and its line, so
// it has no equivalent in a binary (declared difference of the port; the comparison itself reads as false).
var reBashTestErr = regexp.MustCompile(`(?m)^[^\n]*sweep-audits\.sh: line [0-9]+: \[: [^\n]*integer expression expected\n`)

// reBashTestErrJSON is the same line inside the hook envelope, where the newlines are JSON escapes.
var reBashTestErrJSON = regexp.MustCompile(`(\\n|")[^"\\]*sweep-audits\.sh: line [0-9]+: \[: [^"\\]*integer expression expected\\n`)

func normAuditsErr(s string) string { return reBashTestErr.ReplaceAllString(normStderr(s), "") }

func normAuditsOut(s string) string { return reBashTestErrJSON.ReplaceAllString(normOut(s), "$1") }

func (w *world) sameAudits(what string, goRes, bashRes result) {
	w.t.Helper()
	if goRes.rc != bashRes.rc || normAuditsOut(goRes.out) != normAuditsOut(bashRes.out) || normAuditsErr(goRes.err) != normAuditsErr(bashRes.err) {
		w.t.Errorf("%s differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
			what, goRes.rc, goRes.out, goRes.err, bashRes.rc, bashRes.out, bashRes.err)
	}
}

func TestAuditsDifferential(t *testing.T) {
	for _, sc := range auditScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			sc.setup(w)
			w.sameAudits("report", w.runAudits(sc.args...), w.bashAudits("sweep-audits.sh", sc.args...))
			w.sameAudits("hook", w.runAuditsHook(), w.bashAudits("sweep-audits-hook.sh"))
			w.sameAudits("hook --full", w.runAuditsHook("--full"), w.bashAudits("sweep-audits-hook.sh", "--full"))
		})
	}
}

// TestAuditsDifferentialOrder pins the readdir order of the INFO lines and the tie-break of audits of the same
// age, over a target whose audits sit at several depths, beside entries that must not count.
func TestAuditsDifferentialOrder(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, n := range []string{"b.md", "a.md", "C.md", "10.md", "2.md", "z.md", "m.md"} {
		w.put(a+"/audits/"+n, auditText("", 1))
	}
	for _, d := range []string{"x/audits", "x/y/audits", "x/y/z/audits", "x/y/z/w/audits"} {
		w.put(a+"/"+d+"/n.md", auditText("<!-- review-status: wip -->", 2))
	}
	w.put(a+"/audits/sub/dir/deep.md", auditText("", 3))
	w.put(a+"/audits/.hidden.md", auditText("", 1))
	w.put(a+"/audits/notes.txt", "not markdown\n")
	w.put(a+"/.git/audits/in-git.md", auditText("", 1))
	w.must(os.Symlink(a+"/audits/a.md", a+"/audits/link.md"))
	w.must(os.Symlink(a+"/x", a+"/linkdir"))
	w.targets(a)
	w.sameAudits("report", w.runAudits(), w.bashAudits("sweep-audits.sh"))
}

// TestAuditsDifferentialThreshold covers the values bash `[ n -gt v ]` accepts or refuses.
func TestAuditsDifferentialThreshold(t *testing.T) {
	for _, v := range []string{"7", "0", "-1", "+3", " 3", "3 ", "03", "08", "abc", "", "1.5", "99999999999999999999", "0x10"} {
		t.Run("value "+v, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			a := w.tgt("targetA")
			for i, age := range []int{0, 2, 3, 4, 9} {
				w.audit(a, string(rune('a'+i))+".md", auditPending, 1)
				w.touch(a+"/audits/"+string(rune('a'+i))+".md", time.Duration(age)*day+hour)
			}
			w.env["RSDD_RETRO_AGE_DAYS"] = v
			w.targets(a)
			w.sameAudits("report", w.runAudits(), w.bashAudits("sweep-audits.sh"))
		})
	}
}
