//go:build !nodiff

package migratebacklogs

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

// Differential test: the FROZEN legacy script (testdata/legacy, byte-identical to the bash that shipped before the
// port) and the Go command run the same case on the same corpus; stdout, stderr and the exit code must be equal.
// The legacy side also (re)generates testdata/golden/cases.json with MIGRATE_BACKLOGS_UPDATE=1, so golden_test.go,
// which runs everywhere (including gremlins' -tags nodiff builds), checks the port against the same recorded
// behaviour without bash driving the legacy script.
//
// Only a missing bash skips, with a message saying the port is NOT proven in that run.

//go:embed testdata/legacy
var legacyFS embed.FS

// The frozen oracle is deliberate: refreeze by copying the files from the toolbelt and updating the digests in the
// same commit.
var legacyPins = map[string]string{
	"testdata/legacy/migrate-backlogs.sh": "92a0f50c07d9900c85739d494a131801c167d7616485192ef7cfaea12e5f13cb",
	"testdata/legacy/lib/state-files.sh":  "fe8e1798b6b8e6de81152baa854d008c6e7cf841918bd7f55c3f95924ae32989",
}

func TestLegacyOracleIsFrozen(t *testing.T) {
	for path, want := range legacyPins {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		sum := sha256.Sum256(data)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s changed: sha256 %s, pinned %s", path, got, want)
		}
	}
}

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): MIGRATE_BACKLOGS_UPDATE=1 go test
// -run TestDifferential. An environment variable, not a flag: a flag only this package defines would fail the other
// packages of a repo-wide run.
func updateGoldens() bool { return os.Getenv("MIGRATE_BACKLOGS_UPDATE") == "1" }

// extractLegacy writes the frozen script and its helper library under dir, the layout the script expects.
func extractLegacy(t *testing.T, dir string) string {
	t.Helper()
	err := fs.WalkDir(legacyFS, "testdata/legacy", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := legacyFS.ReadFile(p)
		if err != nil {
			return err
		}
		out := filepath.Join(dir, p[len("testdata/legacy/"):])
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		return os.WriteFile(out, data, 0o755)
	})
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "migrate-backlogs.sh")
}

func runLegacy(t *testing.T, bash, root, corpus string, args []string) result {
	t.Helper()
	script := extractLegacy(t, filepath.Join(root, "toolbelt"))
	before := treeFingerprint(t, corpus)
	cmd := exec.Command(bash, append([]string{script}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C", "HOME=" + root}
	cmd.Dir = root
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
	if after := treeFingerprint(t, corpus); after != before {
		t.Errorf("the legacy script changed the corpus: its oracle role is void")
	}
	return result{RC: rc, Stdout: normalize(root, so.String()), Stderr: normalize(root, se.String())}
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
				root, corpus := c.layout(t)
				args := c.resolveArgs(root, corpus)
				want := runLegacy(t, bash, root, corpus, args)
				mu.Lock()
				recorded[c.name] = want
				mu.Unlock()
				if d := diffResult(want, runGo(t, root, corpus, args)); d != "" {
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
			t.Errorf("%s: the golden is stale against the legacy script (rerun with MIGRATE_BACKLOGS_UPDATE=1):\n%s", name, d)
		}
	}
}
