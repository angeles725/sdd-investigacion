//go:build linux && !nodiff

package adapter

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// goldenPath is where the outcomes of one parity test are recorded for the tool-free (nodiff) build.
func goldenPath(t *testing.T) string {
	return filepath.Join("testdata", "goldens", t.Name()+".json")
}

// pythonOutcomes replays every world under the frozen Python port (same root as the Go world, so path
// hashes are byte-comparable) and returns what it did. RSDD_RECORD_GOLDENS=1 also writes the outcomes
// to testdata/goldens, which the nodiff build compares the Go port against.
func pythonOutcomes(t *testing.T, names []string, worlds map[string]*world) map[string]pyOutcome {
	t.Helper()
	var cases []pyWorld
	for _, n := range names {
		cases = append(cases, pyWorld{Root: worlds[n].root, Steps: worlds[n].steps})
	}
	toolbeltAbs = mustAbs(t, toolbeltDir)
	all := runDriverParallel[[]runResult](t, "script", cases, 4)
	out := map[string]pyOutcome{}
	for i, n := range names {
		w := worlds[n]
		rs := make([]runResult, len(all[i]))
		for j, r := range all[i] {
			rs[j] = runResult{RC: r.RC, Out: norm(r.Out, w.root), Err: norm(r.Err, w.root), Crash: norm(r.Crash, w.root)}
		}
		out[n] = pyOutcome{Results: rs, Tree: w.tree(w.root)}
	}
	if os.Getenv("RSDD_RECORD_GOLDENS") != "" {
		b, err := json.MarshalIndent(out, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(goldenPath(t)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenPath(t), append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return out
}
