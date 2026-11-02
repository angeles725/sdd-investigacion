//go:build !nodiff

package stageissues

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential tests: the FROZEN legacy script (testdata/legacy, byte-identical to the bash that shipped before
// the port) and the Go command run the same case in the same box; stdout, stderr, the exit code, the fake gh's
// call log and its state files must be equal. The legacy side also (re)generates testdata/golden with -update, so
// golden_test.go, which runs everywhere (including gremlins' -tags nodiff builds), checks the port against the
// same recorded behaviour without bash driving the legacy script.
//
// Only a missing bash skips, with a message saying the port is NOT proven in that run.

func runLegacy(t *testing.T, bash string, b *box, c dcase) result {
	t.Helper()
	stub := filepath.Join(b.root, "stub-legacy")
	seedStub(t, stub, c)
	cmd := exec.Command(bash, append([]string{filepath.Join(b.toolbt, "stage-retro-issues.sh")}, c.argList(b)...)...)
	cmd.Env = envFor(t, b, c, stub)
	cmd.Dir = c.workDir(b)
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
	r := collect(b, stub, rc, so.String(), se.String())
	// Declared divergence: legacy-only gawk locale noise (see dropGawkNoise); the Go port never emits it.
	r.Stderr = dropGawkNoise(r.Stderr)
	r.Stderr = dropBashNoise(c.name, r.Stderr)
	return r
}

func TestDifferential(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found in PATH; the Go port is NOT proven against the legacy script in this run")
	}
	for _, c := range allCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			c = c.resolve(t)
			b := mkBox(t, c)
			want := runLegacy(t, bash, b, c)
			got := runGo(t, b, c)
			if c.name == "titles/invalid-utf8-over-120-utf8" && !strings.Contains(want.Stderr, "note: covers_through") {
				t.Errorf("the gawk-noise filter must leave the rest of stderr to be compared byte for byte; legacy stderr: %q", want.Stderr)
			}
			if d := diffResult(want, got); d != "" {
				t.Errorf("Go differs from the legacy script:\n%s", d)
			}
			if updateGoldens() {
				data, _ := json.MarshalIndent(want.packed(), "", "  ")
				if err := os.WriteFile(goldenPath(c.name), append(data, '\n'), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			if d := diffResult(readGolden(t, c.name), want); d != "" {
				t.Errorf("the golden is stale against the legacy script (rerun with STAGEISSUES_UPDATE=1):\n%s", d)
			}
		})
	}
}
