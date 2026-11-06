//go:build unix && !nodiff

package deploy

import (
	"flag"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// updateGolden follows the sibling convention (internal/install/detect_golden_test.go): the flag rewrites the golden
// files from the current run, and an absent golden is a failure, never a pass.
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden from the current output")

// fromGolden as a wanted stdout or stderr means "compare with the golden file of this step"; any other value is an
// inline expectation (short outputs live in the scenario, long ones in testdata/golden).
const fromGolden = "\x00golden"

// check asserts every observable effect of one run: exit code, stdout, stderr and the resulting tree of home, tmp and
// cwd (the places the installer can write). label names the step inside the scenario.
func (w *world) check(label string, r result, rc int, out, errText string) {
	w.t.Helper()
	if r.RC != rc {
		w.t.Errorf("%s: exit %d, want %d\nstdout:\n%s\nstderr:\n%s", label, r.RC, rc, r.Out, r.Err)
	}
	w.text(label, "out", r.Out, out)
	w.text(label, "err", r.Err, errText)
	w.text(label, "tree", w.tree(), fromGolden)
}

// tree is the normalized snapshot of everything the installer may have written.
func (w *world) tree() string {
	return "home:\n" + w.snapshot(w.home) + "tmp:\n" + w.snapshot(w.tmp) + "cwd:\n" + w.snapshot(w.cwd)
}

func (w *world) text(label, kind, got, want string) {
	w.t.Helper()
	if want != fromGolden {
		if got != want {
			w.t.Errorf("%s %s differs\n%s", label, kind, firstDiff(want, got))
		}
		return
	}
	p := filepath.Join("testdata", "golden", strings.ReplaceAll(w.t.Name(), "/", "_"), label+"."+kind)
	if *updateGolden {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			w.t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(got), 0o644); err != nil {
			w.t.Fatal(err)
		}
	}
	b, err := os.ReadFile(p)
	if err != nil {
		w.t.Fatalf("golden unreadable (an absent golden proves nothing; record with -update-golden): %v", err)
	}
	if string(b) != got {
		w.t.Errorf("%s %s differs from %s\n%s", label, kind, p, firstDiff(string(b), got))
	}
}

// firstDiff names the first line on which the two texts differ.
func firstDiff(a, b string) string {
	al, bl := strings.Split(a, "\n"), strings.Split(b, "\n")
	for i := 0; i < len(al) || i < len(bl); i++ {
		var x, y string
		if i < len(al) {
			x = al[i]
		}
		if i < len(bl) {
			y = bl[i]
		}
		if x != y {
			return "first difference at line " + strconv.Itoa(i+1) + ":\n  want: " + x + "\n  got:  " + y
		}
	}
	return "(no line differs)"
}
