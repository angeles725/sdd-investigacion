package writercheck

import (
	"strings"
	"testing"
)

// The decisions below used to sit in tagless switches; each case pins both sides of the comparison.

func TestExitCodeOf(t *testing.T) {
	for _, c := range []struct {
		rc     int
		reason string
		want   int
	}{
		{0, "", 0}, {1, "", 1}, {-1, "", 129}, {-9, "", 137},
		{0, "timeout", 124}, {5, "timeout", 124}, {-1, "timeout", 124},
	} {
		if got := exitCodeOf(c.rc, c.reason); got != c.want {
			t.Errorf("exitCodeOf(%d, %q) = %d, want %d", c.rc, c.reason, got, c.want)
		}
	}
}

func TestIsProductionBoundaries(t *testing.T) {
	const tb, ts = "research-sdd/toolbelt/", "research-sdd/toolbelt/tests/"
	for _, c := range []struct {
		path string
		want bool
	}{
		{tb + "x.sh", true},
		{"research-sdd/install/x.py", true},
		{"research-sdd/templates/x.mjs", true},
		{tb + "x.txt", false},
		{"research-sdd/other/x.sh", false},
		{ts + "run-all.sh", true},
		{ts + "a.test.sh", false},
		{ts + "fixtures/x.sh", false},
		{ts + "lib/x.sh", true},
		{ts + "lib/sub/x.test.sh", true},
		{ts + "sub/x.sh", false},
		{ts[:len(ts)-1] + "x.sh", true}, // "tests" without the slash is a sibling file, not the directory
		{"research-sdd/install/tests/x.sh", false},
		{"research-sdd/install/x.test.sh", true},
	} {
		if got := isProduction(c.path); got != c.want {
			t.Errorf("isProduction(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestCheckLogCountsAreComparedAsText(t *testing.T) {
	const h = "# writer-check: head=abc tree=0123456789012345678901234567890123456789"
	dir := t.TempDir()
	for _, c := range []struct{ name, summary, kind, why string }{
		{"one passed", "== 1 passed · 0 failed ==", "", ""},
		{"zero padded passed", "== 00 passed · 0 failed ==", "", ""},
		{"zero padded failed", "== 3 passed · 00 failed ==", missing, "summary reports failures"},
		{"one failed", "== 3 passed · 1 failed ==", missing, "summary reports failures"},
	} {
		writeFile(t, dir+"/"+logName("s.test.sh"), h+"\n-- teeth --\n"+c.summary+"\n")
		kind, why := checkLog(dir, "s.test.sh", h)
		if kind != c.kind || !strings.HasPrefix(why, c.why) {
			t.Errorf("%s: got %q %q, want %q %q", c.name, kind, why, c.kind, c.why)
		}
	}
}
