package archtest

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// oracleAllow lists the oracle test files still built under -tags nodiff. Each
// entry is debt: fix the package (tag the file `!nodiff` and move the kills its
// oracle made into unit or golden tests, teeth Lived 0), then delete the line.
// A line whose file is fixed or gone fails TestOracleTagsRealTree as stale.
var oracleAllow = map[string]string{
	"internal/core/adapter/driver_helpers_test.go":       "python adapter oracle; session 1 core-consolidation T2",
	"internal/core/adapter/helpers/parity_linux_test.go": "python adapter oracle; session 1 core-consolidation T2",
	"internal/core/adapter/nfkc_test.go":                 "python adapter oracle; session 1 core-consolidation T2",
	"internal/core/adapter/parity_linux_test.go":         "python adapter oracle; session 1 core-consolidation T2",
	"internal/core/adapter/profile_test.go":              "python adapter oracle; session 1 core-consolidation T2",
	"internal/core/hookwiring/differential_test.go":      "frozen bash oracle (testdata/legacy); follow-up issue",
	"internal/corroborate/floss/world_test.go":           "runs the live analysis_manifest.py; goes with its deletion (core-consolidation T3)",
	"internal/corroborate/pcap/command_linux_test.go":    "runs the live analysis_manifest.py; goes with its deletion (core-consolidation T3)",
	"internal/formats/squashfs_test.go":                  "python oracle; PR B formats slice",
	"internal/formats/zipcmd_linux_test.go":              "python oracle; PR B formats slice",
	"internal/formats/zipparity_linux_test.go":           "python oracle; PR B formats slice",
	"internal/gate/mergeharness_test.go":                 "frozen bash oracle (testdata/legacy); follow-up issue",
	"internal/gate/mergetrain_test.go":                   "frozen bash oracle (testdata/legacy); follow-up issue",
	"internal/lint/helpers_test.go":                      "frozen bash oracle (testdata/legacy); follow-up issue",
}

func TestOracleTagsFixture(t *testing.T) {
	allow := map[string]string{
		"internal/a/allowed_test.go": "fixture: allowlisted",
		"internal/a/tagged_test.go":  "fixture: already tagged, so stale",
		"internal/a/gone_test.go":    "fixture: no such file, so stale",
	}
	r, err := CheckOracleTags(filepath.Join("testdata", "oracle"), allow)
	if err != nil {
		t.Fatal(err)
	}
	if r.Scanned != 11 {
		t.Errorf("Scanned = %d, want 11", r.Scanned)
	}
	check := func(name string, got, want []string) {
		t.Helper()
		if !slices.Equal(got, want) {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	p := func(names ...string) []string {
		out := make([]string, len(names))
		for i, n := range names {
			out[i] = "internal/a/" + n + "_test.go"
		}
		return out
	}
	// comment_test.go names an oracle only in a comment; literal_only_test.go has a
	// marker but never execs; shadow_test.go calls Command on a local `exec` that is
	// not os/exec: none is an oracle file. alias_test.go imports os/exec as osexec.
	check("Oracles", r.Oracles, p("alias", "allowed", "legacy", "other_nodiff", "script", "tagged", "untagged", "winonly_windows"))
	// legacy_test.go's `!windows` keeps it in a linux nodiff build; other_nodiff_test.go's
	// `!nodiff || windows` does not, and winonly_windows_test.go is not built on linux at all.
	check("Untagged", r.Untagged, p("alias", "legacy", "script", "untagged"))
	check("Stale", r.Stale, p("gone", "tagged"))
}

func TestOracleTagsEmptyTreeIsAnError(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "internal"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := CheckOracleTags(root, nil); err == nil {
		t.Fatal("a tree with no _test.go file must be an error, not a pass")
	}
	if _, err := CheckOracleTags(filepath.Join(root, "absent"), nil); err == nil {
		t.Fatal("an absent tree must be an error, not a pass")
	}
}

// TestOracleTagsRealTree enforces the rule on the live module.
func TestOracleTagsRealTree(t *testing.T) {
	r, err := CheckOracleTags(filepath.Join("..", "..", ".."), oracleAllow)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Oracles) == 0 {
		t.Fatal("found zero oracle test files: the detector no longer sees the tree")
	}
	for _, f := range r.Untagged {
		t.Errorf("%s execs a legacy oracle but is built under -tags nodiff: add `!nodiff` to its //go:build line and keep its kills in unit/golden tests", f)
	}
	for _, f := range r.Stale {
		t.Errorf("oracleAllow entry %s is stale (file tagged, gone or no longer an oracle): delete it", f)
	}
}
