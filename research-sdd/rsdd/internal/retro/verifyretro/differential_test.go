//go:build !nodiff

package verifyretro

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
// the port) and the Go port run the same case in the same box; stdout, stderr and the exit code must be equal.
// The legacy side also (re)generates testdata/golden/cases.json with VERIFYRETRO_UPDATE=1, so golden_test.go,
// which runs everywhere (including gremlins' -tags nodiff builds), checks the port against the same recorded
// behaviour without bash driving the legacy script.
//
// Only a missing bash skips, with a message saying the port is NOT proven in that run.

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): VERIFYRETRO_UPDATE=1 go test
// -run TestDifferential. An environment variable, not a flag: a flag only this package defines would fail the
// other packages of a repo-wide run.
func updateGoldens() bool { return os.Getenv("VERIFYRETRO_UPDATE") == "1" }

func runLegacy(t *testing.T, bash string, b *box) result {
	t.Helper()
	tb := filepath.Join(b.root, "tb")
	mustMkdir(t, filepath.Join(tb, "lib"))
	copyFile(t, "testdata/legacy/verify-retro.sh", filepath.Join(tb, "verify-retro.sh"))
	copyFile(t, "testdata/legacy/lib/retro-grammar.sh", filepath.Join(tb, "lib", "retro-grammar.sh"))
	cmd := exec.Command(bash, append([]string{filepath.Join(tb, "verify-retro.sh")}, b.args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C", "HOME=" + b.root, "TMPDIR=" + b.root}
	cmd.Dir = b.cwd
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
	return b.normalize(rc, so.String(), se.String())
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	mustWrite(t, dst, string(data))
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
				lb := mkBox(t, c)
				if c.unreadable {
					// Only the LEGACY side needs a real mode-000 file; root reads it, so the legacy run (not the
					// port, which uses the seam, and not the golden replay) cannot be compared there.
					if os.Geteuid() == 0 {
						t.Skip("differential: root reads a mode-000 file, the legacy script cannot be driven into its unreadable branch; the golden replay still pins the port")
					}
					if err := os.Chmod(lb.retro, 0); err != nil {
						t.Fatal(err)
					}
				}
				want := runLegacy(t, bash, lb)
				mu.Lock()
				recorded[c.name] = want
				mu.Unlock()
				if d := diffResult(want, runGo(t, mkBox(t, c))); d != "" {
					t.Errorf("Go differs from the legacy script:\n%s", d)
				}
			})
		}
	})
	if updateGoldens() {
		// The whole set or nothing: a -run filter, a skipped case or a panicking one would otherwise erase the
		// goldens of every case that did not run.
		if len(recorded) != len(cases) {
			t.Fatalf("refusing to write goldens: %d of %d cases ran (run without -run, as non-root)", len(recorded), len(cases))
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
			t.Errorf("%s: the golden is stale against the legacy script (rerun with VERIFYRETRO_UPDATE=1):\n%s", name, d)
		}
	}
}
