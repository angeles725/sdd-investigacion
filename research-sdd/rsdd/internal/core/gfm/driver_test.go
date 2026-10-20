package gfm

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The bash driver is the parity oracle: when the reader it runs fails, the driver must fail loudly with a typed
// stderr message (kit CLAUDE.md section 7). A swallowed failure would let the Go differential pass against an
// oracle that never ran. These tests point the driver at a FAKE toolbelt whose readers fail or print nothing.

func fakeToolbelt(t *testing.T, statusScript string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "research-sdd-status.sh"), []byte(statusScript), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func runDriver(t *testing.T, tb, mode, file string, keys ...string) (stdout, stderr string, exit int) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("driver test: bash not found in PATH; the oracle driver is NOT tested in this run")
	}
	script, _ := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	cmd := exec.Command("bash", append([]string{script, tb, mode, file}, keys...)...)
	var so, se strings.Builder
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return so.String(), se.String(), ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return so.String(), se.String(), 0
}

func TestDriverFailsLoudlyOnReaderError(t *testing.T) {
	envelope := filepath.Join(t.TempDir(), "state.md")
	if err := os.WriteFile(envelope, []byte("deferred_open: 3\ncovered_blocks: 4\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	plain := filepath.Join(t.TempDir(), "plain.md")
	if err := os.WriteFile(plain, []byte("| a |\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, mode, file, script string
		keys                     []string
	}{
		{"state: script exits non-zero", "state", envelope, "echo boom >&2\nexit 3\n", nil},
		{"state: script ok but envelope values never appear", "state", plain, "exit 0\n", nil},
		{"foctok: reader function fails", "foctok", plain, "_read_focuses_tok_uncached() {\n  echo boom >&2\n  return 4\n}\n", []string{"k1"}},
		{"contra: reader function fails", "contra", plain, "count_open_contra() {\n  echo boom >&2\n  return 5\n}\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, exit := runDriver(t, fakeToolbelt(t, c.script), c.mode, c.file, c.keys...)
			if exit == 0 {
				t.Fatalf("driver exited 0 on a failing reader (silent pass); stdout=%q stderr=%q", stdout, stderr)
			}
			if !strings.Contains(stderr, "diff-driver:") {
				t.Errorf("exit %d but no typed `diff-driver:` message on stderr: %q", exit, stderr)
			}
		})
	}
}

func TestDriverShowsReaderStderrInFocusMode(t *testing.T) {
	// A reader that succeeds but warns on stderr: the warning must reach the driver's stderr, not /dev/null.
	plain := filepath.Join(t.TempDir(), "plain.md")
	if err := os.WriteFile(plain, []byte("| a |\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := "_read_focuses_tok_uncached() {\n  echo WARN-VISIBLE >&2\n  echo active\n}\n"
	stdout, stderr, exit := runDriver(t, fakeToolbelt(t, script), "foctok", plain, "k1")
	if exit != 0 || strings.TrimSpace(stdout) != "k1=active" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", exit, stdout, stderr)
	}
	if !strings.Contains(stderr, "WARN-VISIBLE") {
		t.Errorf("reader stderr was suppressed: %q", stderr)
	}
}
