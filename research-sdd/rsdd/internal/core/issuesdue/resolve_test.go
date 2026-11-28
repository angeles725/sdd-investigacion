package issuesdue

import (
	"os"
	"path/filepath"
	"testing"
)

func mustMkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, p, content string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestListLimit(t *testing.T) {
	huge := "99999999999999999999999"
	for _, tc := range []struct {
		in   string
		text string
		n    int
		bad  bool
	}{
		{"", "1000", 1000, false},
		{"1", "1", 1, false},
		{"250", "250", 250, false},
		{"007", "007", 7, false},
		{"00", "00", 0, false}, // `case 0` matches only the single digit: "00" passes, as in bash
		{"0", "0", 0, true},
		{"-1", "-1", 0, true},
		{"1a", "1a", 0, true},
		{" 1", " 1", 0, true},
		{huge, huge, int(^uint(0) >> 1), false},
	} {
		text, n, bad := ListLimit(func(string) string { return tc.in })
		if text != tc.text || n != tc.n || (bad != "") != tc.bad {
			t.Errorf("ListLimit(%q) = (%q, %d, %q), want (%q, %d, bad=%v)", tc.in, text, n, bad, tc.text, tc.n, tc.bad)
		}
		if tc.bad && bad != "degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '"+tc.in+"')" {
			t.Errorf("bad line = %q", bad)
		}
	}
}

// The command resolves the kit root from the toolbelt: relative to the working directory, through symlinks.
func TestKitRoot(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "kit", "research-sdd", "toolbelt")
	mustMkdir(t, real)
	mustWrite(t, filepath.Join(real, "reconcile-issues.sh"), "#!/bin/sh\n")
	link := filepath.Join(root, "link")
	must(t, os.Symlink(real, link))
	var errs []string
	errf := func(f string, a ...any) { errs = append(errs, f) }
	wantKit := filepath.Join(root, "kit")
	for name, tb := range map[string]string{"absolute": real, "through a symlink": link, "relative to cwd": "link"} {
		got, ok := KitRoot(root, func(string) string { return "" }, tb, errf)
		if !ok || got != wantKit {
			t.Errorf("%s: %q %v, want %q", name, got, ok, wantKit)
		}
	}
	// No --toolbelt: the kit resolution (RESEARCH_SDD_KIT).
	env := func(k string) string {
		if k == "RESEARCH_SDD_KIT" {
			return filepath.Join(root, "kit", "research-sdd")
		}
		return ""
	}
	if got, ok := KitRoot(root, env, "", errf); !ok || got != wantKit {
		t.Errorf("kit resolution: %q %v", got, ok)
	}
	if _, ok := KitRoot(root, func(string) string { return "" }, "", errf); ok {
		t.Error("no kit anywhere must fail")
	}
}
