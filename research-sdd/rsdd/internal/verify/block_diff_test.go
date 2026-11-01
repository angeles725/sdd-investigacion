//go:build unix && !nodiff

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential test of `rsdd verify block` against the frozen legacy script (testdata/block/legacy). Every case
// runs both implementations in the same directory and environment; stdout, stderr and the exit code must be
// equal, and equal to the record the golden test reads. RSDD_BLOCK_RECORD=1 rewrites the record from the legacy
// script. A missing bash, git, gawk or GNU grep FAILS: a skipped differential proves nothing.

func runBlockLegacy(t testing.TB, c blockCase) blockRecord {
	t.Helper()
	root, env, args := blockWorld(t, c)
	script, err := filepath.Abs(filepath.Join("testdata", "block", "legacy", "verify-block.sh"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Dir = root
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("%s: bash: %v", c.name, err)
		}
		rc = ee.ExitCode()
	}
	return blockRecord{rc, normalize(root, out.String()), normalize(root, dropShellDiag(errb.String()))}
}

// dropShellDiag removes the diagnostics bash itself prints, named after the script's path and a line number:
// "[: N: integer expression expected" when a cited line number exceeds the integer range, and the redirection
// error when a preserved script cannot be opened for hashing. The Go command reads the first as a false test and
// reports the second through the typed MANIFEST! line; neither prints a shell diagnostic (documented in
// block.go), and the verdict lines are unchanged.
func dropShellDiag(s string) string {
	var keep []string
	for _, l := range strings.Split(s, "\n") {
		if strings.Contains(l, "legacy/verify-block.sh: line ") {
			continue
		}
		keep = append(keep, l)
	}
	return strings.Join(keep, "\n")
}

func TestBlockDifferential(t *testing.T) {
	for _, tool := range []string{"bash", "git", "gawk", "find", "sort", "grep", "sed", "cut", "sha256sum"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("%s is required (a skipped differential proves nothing): %v", tool, err)
		}
	}
	record := os.Getenv("RSDD_BLOCK_RECORD") == "1"
	only := os.Getenv("RSDD_BLOCK_ONLY") // development filter; with RECORD it re-records just those cases
	g := map[string]blockRecord{}
	if !record || only != "" {
		g = loadBlockGolden(t)
	}
	for _, c := range blockCases() {
		if only != "" && !strings.Contains(c.name, only) {
			continue
		}
		want := runBlockLegacy(t, c)
		if record {
			g[c.name] = want
			continue
		}
		if rec, ok := g[c.name]; !ok || rec != want {
			t.Errorf("%s: the recorded golden is stale against the legacy script (re-record with RSDD_BLOCK_RECORD=1)", c.name)
		}
		got := runBlockGo(t, c)
		if got != want {
			t.Errorf("%s differs from the legacy script\nlegacy rc=%d\n%s\n--- stderr: %q\n     go rc=%d\n%s\n--- stderr: %q",
				c.name, want.RC, want.Stdout, want.Stderr, got.RC, got.Stdout, got.Stderr)
		}
	}
	if record {
		writeBlockGolden(t, g)
	}
}
