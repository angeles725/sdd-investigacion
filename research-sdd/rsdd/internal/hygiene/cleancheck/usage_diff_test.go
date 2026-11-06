//go:build !nodiff

package cleancheck

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The command line against the frozen script: every case the parser decides (usage, help, bad numbers, missing
// values, the order faults are reported in) prints the same bytes on the same streams and exits the same way. The
// golden form of these cases is the hand-written table of TestParseRefuses and TestRunUsageAndHelp.
func TestUsageDifferential(t *testing.T) {
	legacy := t.TempDir()
	for _, f := range []string{"clean-check.sh", "lib/scripts-manifest.sh"} {
		b, err := os.ReadFile(filepath.Join("..", "..", "core", "cleancheck", "testdata", "legacy", f))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(legacy, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(legacy, f), b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{
		{"--bogus"}, {"positional"}, {""}, {"--stale-hours"}, {"--stale-hours", "abc"}, {"--stale-hours", ""}, {"--stale-hours", "-1"},
		{"--stale-hours", "1234567890"}, {"--backup-days", "x"}, {"--backup-days", "1234567890"}, {"--target"}, {"--tmp"}, {"--scratchpad"},
		{"--base"}, {"--evidence"}, {"--backup-days"}, {"-h"}, {"--help"}, {"-h", "--bogus"}, {"--bogus", "-h"},
		{"--bogus", "--stale-hours", "abc"}, {"--backup-days", "z", "--stale-hours", "y"}, {"--stale-hours", "08", "--bogus"},
		{"--target", "--tmp"}, {"--target", "/nonexistent-clean-check-target"}, {"--stale-hours", "1.5"}, {"--stale-hours", "+1"},
	} {
		w := newWorld(t)
		c := exec.Command("bash", append([]string{legacy + "/clean-check.sh"}, args...)...)
		c.Dir, c.Env = w.root, w.env
		var lo, le bytes.Buffer
		c.Stdout, c.Stderr = &lo, &le
		rc := 0
		if err := c.Run(); err != nil {
			ee, ok := err.(*exec.ExitError)
			if !ok {
				t.Fatal(err)
			}
			rc = ee.ExitCode()
		}
		got := w.run(nil, args...)
		if got != rc || w.out.String() != lo.String() || w.err.String() != le.String() {
			t.Errorf("%q\nlegacy rc %d out %q err %q\ngo     rc %d out %q err %q", strings.Join(args, " "), rc, lo.String(), le.String(), got, w.out.String(), w.err.String())
		}
	}
}
