//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The differential of `sweep breakthroughs`: the frozen sweep-breakthroughs.sh and sweep-breakthroughs-hook.sh
// (the bytes of the scripts before the port, sha-pinned by breakthroughs_pin_test.go; the live ones are shims
// now) run beside the Go commands in the same world. The scripts source the LIVE toolbelt/lib through a staged lib
// link, so the bash libs stay under test too. Stdout, stderr and the exit code must be equal. A missing bash or jq
// FAILS: a skipped differential proves nothing. Rows marked nodiff are the declared differences and are not
// compared.

const btLegacyDir = "testdata/breakthroughs/legacy/"

// stageBT puts the frozen scripts in <kit>/toolbelt, with lib/ linked to the live library.
func (w *world) stageBT() {
	w.t.Helper()
	lib, err := filepath.Abs(toolbelt + "/lib")
	w.must(err)
	for _, n := range []string{"sweep-breakthroughs.sh", "sweep-breakthroughs-hook.sh"} {
		b, err := os.ReadFile(btLegacyDir + n)
		w.must(err)
		w.must(os.WriteFile(w.kit+"/toolbelt/"+n, b, 0o755))
	}
	if _, err := os.Lstat(w.kit + "/toolbelt/lib"); err != nil {
		w.must(os.Symlink(lib, w.kit+"/toolbelt/lib"))
	}
}

// bashBT runs a staged frozen script.
func (w *world) bashBT(script string, args ...string) result {
	w.t.Helper()
	w.stageBT()
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

func (w *world) sameBT(what string, goRes, bashRes result) {
	w.t.Helper()
	if goRes != bashRes {
		w.t.Errorf("%s differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
			what, goRes.rc, goRes.out, goRes.err, bashRes.rc, bashRes.out, bashRes.err)
	}
}

// compareBT runs the report, the hook and the hook --full of the Go command and of the frozen scripts.
func (w *world) compareBT(args ...string) {
	w.t.Helper()
	w.sameBT("report", w.runBT(args...), w.bashBT("sweep-breakthroughs.sh", args...))
	w.sameBT("hook", w.runBTHook(), w.bashBT("sweep-breakthroughs-hook.sh"))
	w.sameBT("hook --full", w.runBTHook("--full"), w.bashBT("sweep-breakthroughs-hook.sh", "--full"))
}

func TestBreakthroughsDifferential(t *testing.T) {
	for _, sc := range btScenarios() {
		if sc.nodiff != "" {
			continue
		}
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			sc.setup(w)
			w.compareBT(sc.args...)
		})
	}
}

// TestBreakthroughsDifferentialOrder pins the order of the lines over blocks at several depths, in names that sort
// differently by bytes and by case, beside entries that must not count.
func TestBreakthroughsDifferentialOrder(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, n := range []string{"b-block1.md", "a-block1.md", "C-block1.md", "a-block10.md", "a-block2.md", "z-bloque3.md", "m-block1-x.md"} {
		w.block(a, n, true)
	}
	for _, d := range []string{"x", "x/y", "x/y/z", "x/y/z/w/v/u"} {
		w.block(a+"/"+d, "n-block1.md", true)
	}
	w.block(a+"/.hidden", "h-block1.md", true)
	w.block(a, ".dot-block1.md", true)
	w.block(a, "notes.txt", true)
	w.must(os.Symlink(a+"/a-block1.md", a+"/link-block1.md"))
	w.must(os.Symlink(a+"/x", a+"/linkdir"))
	w.targets(a)
	w.btLedger(btRow(ptr(a+"/a-block1.md", 7)))
	w.compareBT()
}

// TestBreakthroughsDifferentialLedger pins the ledger forms: pointers in several cells and rows, a pointer with
// a colon in its path, the first and the last cell, a line without a closing pipe, CRLF rows.
func TestBreakthroughsDifferentialLedger(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, n := range []string{"a-block1.md", "b-block1.md", "c-block1.md"} {
		w.block(a, n, true)
	}
	w.block(w.tgt("colon:dir"), "d-block1.md", true)
	w.targets(a, w.root+"/colon:dir")
	w.btLedger(
		"|1|t|w|`"+a+"/a-block1.md:7`|k|",
		"| 2 | t | w | text `"+a+"/b-block1.md:7` more `"+a+"/c-block1.md:3` | `"+a+"/a-block1.md:99` |",
		"| 3 | t | w | `"+w.root+"/colon:dir/d-block1.md:7` |",
		"| 4 | t | w | `"+a+"/nope:x:7` `no-colon` `a:b` ``:3 `:5` |",
		"| 5 | t | w\t| `"+a+"/a-block1.md:0` |\r",
		"  | 6 | t | w | `"+a+"/a-block1.md:7` | indented, not a row",
		"| 7 | t | w | `"+a+"/b-block1.md:99999999999999999999` |",
	)
	w.compareBT()
}
