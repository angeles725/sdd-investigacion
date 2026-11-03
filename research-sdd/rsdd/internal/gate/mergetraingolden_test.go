package gate

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// Goldens of the merge-train transcript (testdata/mergetrain/golden/<scenario>.txt): the exit code, stdout, stderr,
// the ordered call log, the receipt and the leftovers of a run, normalised (case directory, run stamp). They pin the
// bytes the differential test proves equal to the bash, so a change to a typed line or the receipt shows up as a
// diff to review. Refresh with MERGETRAIN_UPDATE=1 go test -run MergeTrainGolden ./internal/gate/.
func TestMergeTrainGolden(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("builds git repositories and runs processes")
	}
	golden := map[string]bool{"happy": true, "conflict-mid": true, "bisect-mid": true, "gate-red": true, "mgfail-mid": true,
		"main-raced": true, "oob": true, "usage-dup": true, "dry": true}
	n := 0
	for _, sc := range mtScenarios() {
		if !golden[sc.name] {
			continue
		}
		n++
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			c := newMtCase(t)
			r := c.runGo(sc.setup(c), nil)
			got := fmt.Sprintf("rc: %d\n--- stdout\n%s--- stderr\n%s--- calls\n%s\n--- receipt\n%s--- left behind\n%s\n", r.rc, r.out, r.err, r.calls, r.receipt, r.post)
			path := filepath.Join("testdata", "mergetrain", "golden", sc.name+".txt")
			if os.Getenv("MERGETRAIN_UPDATE") == "1" {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("missing golden %s (MERGETRAIN_UPDATE=1 writes it): %v", path, err)
			}
			if string(want) != got {
				t.Errorf("golden %s differs\n--- want\n%s\n--- got\n%s", path, want, got)
			}
		})
	}
	if n != len(golden) {
		t.Fatalf("golden scenarios found %d of %d: a renamed scenario would silently drop its golden", n, len(golden))
	}
}
