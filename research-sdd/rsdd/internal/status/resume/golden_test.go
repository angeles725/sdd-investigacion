package resume

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// goldenDir holds one file per scenario: the outcome of the frozen scripts (see oracle_test.go -update-resume), with the
// world root and the clock scrubbed. The replay below needs no bash, so mutants of the port are killed without the oracle.
const goldenDir = "testdata/golden"

func goldenPath(name string) string { return filepath.Join(goldenDir, name+".golden") }

// scrubbed is the outcome of a scenario with the world root and the clock scrubbed.
func scrubbed(t testing.TB, sc scn, o outcome) outcome {
	t.Helper()
	w := getWorld(t, sc.world0())
	return outcome{o.rc, normalise(sc, w, o.out), normalise(sc, w, o.err)}
}

// snapshot hashes every path and every byte of a world's repositories (refs, index, config, objects, worktrees),
// one hash per path so a change names the paths it touched.
func snapshot(t testing.TB, w *world) map[string]string {
	t.Helper()
	skip := map[string]bool{"in": true, "paths": true, "stubs": true, "tmp": true, "gh-rec.txt": true, "gitlog.txt": true}
	out := map[string]string{}
	err := filepath.WalkDir(w.root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(w.root, p)
		if skip[strings.SplitN(rel, string(filepath.Separator), 2)[0]] {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		sum := d.Type().String()
		if d.Type().IsRegular() {
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			sum = fmt.Sprintf("%x", sha256.Sum256(b))
		}
		out[rel] = sum
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// changedPaths lists the paths added, removed or rewritten between two snapshots, sorted.
func changedPaths(before, after map[string]string) []string {
	var d []string
	for p, h := range before {
		if a, ok := after[p]; !ok || a != h {
			d = append(d, p)
		}
	}
	for p := range after {
		if _, ok := before[p]; !ok {
			d = append(d, p)
		}
	}
	sort.Strings(d)
	return d
}

func TestGolden(t *testing.T) {
	all := scenarios()
	kinds := map[string]bool{}
	for _, sc := range all {
		kinds[sc.world0()] = true
	}
	var order []string
	for k := range kinds {
		order = append(order, k)
	}
	sort.Strings(order)
	before := map[string]map[string]string{}
	for _, k := range order {
		before[k] = snapshot(t, getWorld(t, k))
	}
	seen := map[string]bool{}
	for _, sc := range all {
		if seen[sc.name] {
			t.Fatalf("duplicate scenario %q", sc.name)
		}
		seen[sc.name] = true
		t.Run(sc.name, func(t *testing.T) {
			o := scrubbed(t, sc, runGo(t, sc))
			want, err := os.ReadFile(goldenPath(sc.name))
			if err != nil {
				t.Fatalf("no golden for %s (record it with -update-resume): %v", sc.name, err)
			}
			if got := goldenText(o); got != string(want) {
				t.Errorf("output differs from the frozen script\n--- want\n%s\n--- got\n%s", want, got)
			}
		})
	}
	for _, k := range order {
		if d := changedPaths(before[k], snapshot(t, getWorld(t, k))); len(d) > 0 {
			t.Errorf("world %s was modified by a read-only command: %q", k, d)
		}
	}
	entries, err := os.ReadDir(goldenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if n, ok := strings.CutSuffix(e.Name(), ".golden"); !ok || !seen[n] {
			t.Errorf("stale golden file %s: no scenario of that name", e.Name())
		}
	}
}
