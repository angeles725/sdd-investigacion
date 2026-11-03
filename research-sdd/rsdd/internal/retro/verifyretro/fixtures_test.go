package verifyretro

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runFixture checks one fixture file of testdata/fixtures the way the command does and returns the exit code
// and stdout.
func runFixture(t *testing.T, name string) (Report, int, string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "fixtures", name+".md"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "r.md"), string(data))
	rep, err := Run(context.Background(), Options{Args: []string{"r.md"}, Cwd: dir})
	if err != nil {
		t.Fatal(err)
	}
	var so, se bytes.Buffer
	rc := rep.Render(&so, &se)
	return rep, rc, so.String()
}

// TestFixtureVerdicts ports the assertions of the pre-port bash suite (verify-retro.test.sh) one for one: each
// fixture's exit code and the finding lines it must (and must not) carry.
func TestFixtureVerdicts(t *testing.T) {
	for _, c := range []struct {
		fixture  string
		rc       int
		has, not []string
	}{
		{"conforming", 0, []string{"OK: conforming"}, nil},
		{"honesty-line", 0, []string{"OK: conforming"}, nil},
		{"kit-retro-exclude", 0, []string{"OK: kit-retro: exclude"}, nil},
		{"marker-missing", 1, []string{"FAIL [marker-missing]", "review-status: pending"}, nil},
		{"absent-section", 1, []string{"FAIL [absent-section]", "Proposed kit deltas"}, []string{"FAIL [empty-section]"}},
		{"unrecognised-heading", 1, []string{"FAIL [unrecognised-heading]", "Consolidated kit deltas by DESTINATION FILE", "Proposed kit deltas"}, []string{"FAIL [zero-rows]"}},
		{"empty-section", 1, []string{"FAIL [empty-section]", "add at least one data row"}, []string{"FAIL [absent-section]", "FAIL [unrecognised-heading]"}},
		{"multi-defect", 1, []string{"FAIL [unrecognised-heading]", "FAIL [zero-rows]"}, nil},
		{"header-hyphen", 0, []string{"WARN [header-punctuation]", "OK: conforming"}, []string{"FAIL [header-missing]"}},
		{"honesty-emdash", 0, []string{"OK: conforming"}, nil},
		{"honesty-nothing-add", 0, []string{"OK: conforming"}, nil},
		{"honesty-in-notes", 1, []string{"FAIL [empty-section]"}, []string{"OK: conforming"}},
		{"ford-update-notice-honesty", 0, []string{"OK: conforming"}, nil},
		{"niagara-tools-search-honesty", 0, []string{"OK: conforming"}, nil},
		{"dirty-lead-hv", 1, []string{"FAIL [empty-section]", "section impure"}, []string{"no §18 honesty line"}},
		{"h2-delta-id-veto", 1, []string{"FAIL [empty-section]", "section impure"}, []string{"no §18 honesty line"}},
	} {
		_, rc, out := runFixture(t, c.fixture)
		if rc != c.rc {
			t.Errorf("%s: exit %d, want %d", c.fixture, rc, c.rc)
		}
		for _, s := range c.has {
			if !strings.Contains(out, s) {
				t.Errorf("%s: stdout lacks %q", c.fixture, s)
			}
		}
		for _, s := range c.not {
			if strings.Contains(out, s) {
				t.Errorf("%s: stdout must not carry %q", c.fixture, s)
			}
		}
	}
	// multi-defect is one verdict with exactly two findings.
	if rep, _, _ := runFixture(t, "multi-defect"); len(rep.Findings) != 2 {
		t.Errorf("multi-defect: %d findings, want 2", len(rep.Findings))
	}
}
