//go:build !nodiff

package cleancheck

import (
	"encoding/json"
	"flag"
	"os"
	"sort"
	"strings"
	"testing"
)

// updateGolden rewrites testdata/golden/scenarios.json from the frozen legacy script:
//
//	go test ./internal/core/cleancheck -run TestCleanCheckDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

// TestCleanCheckDifferential runs every scenario through the frozen legacy script (testdata/legacy) and through
// Check, in two identical worlds. Exit code, stdout, stderr and the order of the two (the merged `2>&1` view) must
// agree byte for byte. Under -tags nodiff (the mutation run has no bash oracle) the scenarios replay against the
// goldens the oracle produced (golden_test.go).
func TestCleanCheckDifferential(t *testing.T) {
	stage := legacyDir(t)
	golden := map[string]goldenCase{}
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			if sc.skip(t) {
				return
			}
			wl := newWorld(t)
			sc.prepare(wl)
			l := wl.runLegacy(stage, sc.environ(wl), sc.args(wl)...)
			golden[sc.name] = goldenCase{Merged: wl.show(l.merged), Out: wl.show(l.out), Err: wl.show(l.err), RC: l.rc}
			wg := newWorld(t)
			sc.prepare(wg)
			g := Check(wg.optionsFor(sc.environ(wg), sc.args(wg)...))
			if l.rc != sc.want || g.Exit != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy:\n%s\ngo:\n%s", l.rc, g.Exit, sc.want, l.merged, g.Merged())
			}
			if sc.unordered {
				compareAsSets(t, wl, wg, l, g)
				golden[sc.name] = goldenCase{Merged: wg.show(g.Merged()), Out: wg.show(g.Stdout()), Err: wg.show(g.Stderr()), RC: g.Exit}
				return
			}
			if a, b := wl.show(l.merged), wg.show(g.Merged()); a != b {
				t.Errorf("merged output differs\n--- legacy\n%s--- go\n%s", a, b)
			}
			if a, b := wl.show(l.out), wg.show(g.Stdout()); a != b {
				t.Errorf("stdout differs\n--- legacy\n%s--- go\n%s", a, b)
			}
			if a, b := wl.show(l.err), wg.show(g.Stderr()); a != b {
				t.Errorf("stderr differs\n--- legacy\n%s--- go\n%s", a, b)
			}
		})
	}
	if *updateGolden {
		b, err := json.MarshalIndent(golden, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenFile, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// compareAsSets is the comparison of a scenario whose legacy order is the filesystem's: the same lines, in any order.
func compareAsSets(t *testing.T, wl, wg *world, l ran, g Result) {
	t.Helper()
	for _, c := range [][2]string{{wl.show(l.merged), wg.show(g.Merged())}, {wl.show(l.out), wg.show(g.Stdout())}, {wl.show(l.err), wg.show(g.Stderr())}} {
		a, b := sortedLines(c[0]), sortedLines(c[1])
		if strings.Join(a, "\n") != strings.Join(b, "\n") {
			t.Errorf("the line sets differ\n--- legacy\n%s\n--- go\n%s", strings.Join(a, "\n"), strings.Join(b, "\n"))
		}
	}
}

func sortedLines(s string) []string {
	ls := strings.Split(strings.TrimRight(s, "\n"), "\n")
	sort.Strings(ls)
	return ls
}
