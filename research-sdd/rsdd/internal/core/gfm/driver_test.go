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

// fakeToolbelt builds a toolbelt whose reader for mode is the given script: lib/gap-rows.sh for gaprows,
// research-sdd-status.sh for every other mode.
func fakeToolbelt(t *testing.T, mode, script string) string {
	t.Helper()
	dir := t.TempDir()
	name := "research-sdd-status.sh"
	if mode == "gaprows" {
		name = filepath.Join("lib", "gap-rows.sh")
		if err := os.MkdirAll(filepath.Join(dir, "lib"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func runDriver(t *testing.T, tb, mode, file string, keys ...string) (stdout, stderr string, exit int) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("driver test: bash not found in PATH; the oracle driver is NOT tested in this run")
	}
	script, err := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", append([]string{script, tb, mode, file}, keys...)...)
	var so, se strings.Builder
	cmd.Stdout, cmd.Stderr = &so, &se
	err = cmd.Run()
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
		{"state: only deferred_open comes back", "state", envelope, "printf 'deferred_open: 1\\n' > \"$1/RESEARCH-STATE.md\"\n", nil},
		{"state: only covered_blocks comes back", "state", envelope, "printf 'covered_blocks: 1\\n' > \"$1/RESEARCH-STATE.md\"\n", nil},
		{"state: one key twice is not both keys", "state", envelope, "printf 'deferred_open: 1\\ndeferred_open: 2\\n' > \"$1/RESEARCH-STATE.md\"\n", nil},
		{"gaprows: gap_rows_parse fails", "gaprows", plain, "gap_rows_parse() {\n  echo boom >&2\n  return 6\n}\n", nil},
		{"contra: reader function fails", "contra", plain, "count_open_contra() {\n  echo boom >&2\n  return 5\n}\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, exit := runDriver(t, fakeToolbelt(t, c.mode, c.script), c.mode, c.file, c.keys...)
			if exit == 0 {
				t.Fatalf("driver exited 0 on a failing reader (silent pass); stdout=%q stderr=%q", stdout, stderr)
			}
			want := "diff-driver: reader-failed"
			if c.mode == "state" && !strings.Contains(c.name, "non-zero") {
				want = "diff-driver: empty-output" // the script succeeded but did not deliver both envelope keys exactly once
			}
			if !strings.Contains(stderr, want) {
				t.Errorf("exit %d but stderr lacks the typed message %q: %q", exit, want, stderr)
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
	stdout, stderr, exit := runDriver(t, fakeToolbelt(t, "foctok", script), "foctok", plain, "k1")
	if exit != 0 || strings.TrimSpace(stdout) != "k1=active" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", exit, stdout, stderr)
	}
	if !strings.Contains(stderr, "WARN-VISIBLE") {
		t.Errorf("reader stderr was suppressed: %q", stderr)
	}
}
