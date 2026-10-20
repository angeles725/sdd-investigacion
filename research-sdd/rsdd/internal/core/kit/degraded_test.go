package kit

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// Degraded is a typed state, never a quiet empty result (bash prints "" or counts of 0 for each of these).
func TestUnreadableFocusesAndScanDirAreTyped(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	dir, sf := focusDir(t, focusCorpus["en-dash"])
	if err := os.Chmod(filepath.Join(dir, "FOCUSES.md"), 0); err != nil {
		t.Fatal(err)
	}
	if _, o := DerivePrefix(sf); o != PrefixUnreadable {
		t.Errorf("prefix origin %v", o)
	}
	if r := DeriveRange(sf); r.Kind != RangeUnreadable || r.Output() != "" {
		t.Errorf("range %+v", r)
	}
	if got := RangeReport(sf); len(got) != 1 || got[0].Kind != "DEGRADED" {
		t.Errorf("report %+v", got)
	}
	locked := filepath.Join(t.TempDir(), "locked")
	mkfiles(t, locked, "a-block1.md")
	_ = os.Chmod(locked, 0)
	defer os.Chmod(locked, 0o755)
	if _, err := ScanRange(locked, 1, 2, ""); !errors.Is(err, ErrUnreadable) {
		t.Errorf("scan of an unreadable dir: %v", err)
	}
}
