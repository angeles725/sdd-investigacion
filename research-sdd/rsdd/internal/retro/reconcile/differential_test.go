//go:build !nodiff

package reconcile

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sync"
	"testing"
)

// Differential test: the FROZEN legacy script (testdata/legacy, byte-identical to the bash that shipped before
// the port) and the Go port run the same case in the same box; stdout, stderr and the exit code must be equal.
// The legacy side also (re)generates testdata/golden/cases.json with RECONCILE_UPDATE=1, so golden_test.go,
// which runs everywhere (including gremlins' -tags nodiff builds), checks the port against the same recorded
// behaviour without bash driving the legacy script.
//
// Only a missing bash skips, with a message saying the port is NOT proven in that run.

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): RECONCILE_UPDATE=1 go test
// -run TestDifferential. An environment variable, not a flag: a flag only this package defines would fail the
// other packages of a repo-wide run.
func updateGoldens() bool { return os.Getenv("RECONCILE_UPDATE") == "1" }

func runLegacy(t *testing.T, bash string, b *box) result {
	t.Helper()
	tb := filepath.Join(b.root, "research-sdd", "toolbelt")
	mustMkdir(t, filepath.Join(tb, "lib"))
	copyFile(t, "testdata/legacy/reconcile-issues.sh", filepath.Join(tb, "reconcile-issues.sh"))
	for _, l := range []string{"retro-status", "retro-grammar", "target-paths"} {
		copyFile(t, "testdata/legacy/lib/"+l+".sh", filepath.Join(tb, "lib", l+".sh"))
	}
	args := []string{filepath.Join(tb, "reconcile-issues.sh"), "--issues-cache", b.cache}
	if b.closedArg != "" {
		args = append(args, "--closed-cache", b.closedArg)
	}
	cmd := exec.Command(bash, append(args, b.arg)...)
	env := map[string]string{"PATH": os.Getenv("PATH"), "LC_ALL": "C", "HOME": filepath.Join(b.root, "home"), "TMPDIR": b.root}
	for k, v := range b.env {
		env[k] = v
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
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
	return b.normalize(rc, so.String(), dropBashNoise(se.String()))
}

// reNullByteWarning is the bash notice for a NUL byte read by `$(cat file)`: it names the script path and line, a
// legacy-only diagnostic the port does not emit (it drops the byte silently, like the substitution does).
var reNullByteWarning = regexp.MustCompile(`(?m)^[^\n]*reconcile-issues\.sh: line [0-9]+: warning: command substitution: ignored null byte in input\n`)

// dropBashNoise removes the declared divergence from the legacy stderr; the rest is compared byte for byte.
func dropBashNoise(stderr string) string { return reNullByteWarning.ReplaceAllString(stderr, "") }

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
	var mu sync.Mutex
	recorded := map[string]result{}
	t.Run("cases", func(t *testing.T) {
		for _, c := range allCases() {
			t.Run(c.name, func(t *testing.T) {
				t.Parallel()
				want := runLegacy(t, bash, mkBox(t, c))
				got := runGo(t, mkBox(t, c))
				if d := diffResult(want, got); d != "" {
					t.Errorf("Go differs from the legacy script:\n%s", d)
				}
				mu.Lock()
				recorded[c.name] = want
				mu.Unlock()
			})
		}
	})
	if updateGoldens() {
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
			t.Errorf("%s: the golden is stale against the legacy script (rerun with RECONCILE_UPDATE=1):\n%s", name, d)
		}
	}
}
