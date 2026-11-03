//go:build !nodiff

package stage

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

// Differential test: the FROZEN legacy script (testdata/legacy, byte-identical to the bash that shipped before
// the port) and the Go command run the same case, each on its own byte-identical box; stdout, stderr, the exit
// code and the final state of the repository (HEAD, refs, upstreams, status, worktrees, branch config) must be
// equal. The legacy side also (re)generates testdata/golden/cases.json with STAGE_UPDATE=1, so golden_test.go,
// which runs everywhere (including gremlins' -tags nodiff builds), checks the port against the same recorded
// behaviour without bash driving the legacy script.
//
// Only a missing bash skips, with a message saying the port is NOT proven in that run.

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): STAGE_UPDATE=1 go test
// -run TestDifferential. An environment variable, not a flag: a flag only this package defines would fail the
// other packages of a repo-wide run.
func updateGoldens() bool { return os.Getenv("STAGE_UPDATE") == "1" }

func runLegacy(t *testing.T, bash string, f *fx, c dcase) result {
	t.Helper()
	args, cwd := c.resolve(f)
	cmd := exec.Command(bash, append([]string{filepath.Join(c.toolbelt(f), "stage-retro.sh")}, args...)...)
	cmd.Env, cmd.Dir = f.env, cwd
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	rc := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("legacy run: %v", err)
		}
		rc = ee.ExitCode()
	}
	return f.collect(rc, so.String(), se.String())
}

func TestDifferential(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found in PATH; the Go port is NOT proven against the legacy script in this run")
	}
	cases := allCases()
	var mu sync.Mutex
	recorded := map[string]result{}
	t.Run("cases", func(t *testing.T) {
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				t.Parallel()
				want := runLegacy(t, bash, mkBox(t, c), c)
				mu.Lock()
				recorded[c.name] = want
				mu.Unlock()
				gb := mkBox(t, c)
				if d := diffResult(c.expect(want, gb), runGo(t, gb, c)); d != "" {
					t.Errorf("Go differs from the legacy script:\n%s", d)
				}
			})
		}
	})
	if updateGoldens() {
		// The whole set or nothing: a -run filter or a panicking case would erase the goldens of every case that
		// did not run.
		if len(recorded) != len(cases) {
			t.Fatalf("refusing to write goldens: %d of %d cases ran (run without -run)", len(recorded), len(cases))
		}
		data, err := json.MarshalIndent(recorded, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenPath, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	golden := readGoldens(t)
	for name, want := range recorded {
		if d := diffResult(golden[name], want); d != "" {
			t.Errorf("%s: the golden is stale against the legacy script (rerun with STAGE_UPDATE=1):\n%s", name, d)
		}
	}
}
