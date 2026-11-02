//go:build linux && nodiff

package adapter

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// pythonOutcomes returns the outcomes the frozen Python port recorded for this test (see
// world_oracle_test.go). A missing or short golden fails: a silent skip would prove nothing.
func pythonOutcomes(t *testing.T, names []string, _ map[string]*world) map[string]pyOutcome {
	t.Helper()
	p := filepath.Join("testdata", "goldens", t.Name()+".json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("golden %s: %v (record it with RSDD_RECORD_GOLDENS=1 go test ./internal/core/adapter/)", p, err)
	}
	var out map[string]pyOutcome
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("golden %s: %v", p, err)
	}
	for _, n := range names {
		if _, ok := out[n]; !ok {
			t.Fatalf("golden %s has no outcome for world %q: re-record it", p, n)
		}
	}
	if len(out) != len(names) {
		t.Fatalf("golden %s holds %d worlds, the test builds %d: re-record it", p, len(out), len(names))
	}
	return out
}
