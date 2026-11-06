package archtest

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestFileSizesRealTree enforces the file-size ratchet on the live module.
// With RSDD_MODULARITY_UPDATE=1 it first lowers or deletes stale debt lines
// (never raising a count or adding an entry); without it nothing is written.
func TestFileSizesRealTree(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	debt := filepath.Join(root, DebtFileName)
	changed, err := UpdateDebtIfRequested(os.Getenv(UpdateEnv), root, debt)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Logf("update mode: %s was rewritten", DebtFileName)
	}
	r, err := CheckFileSizes(root, debt)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("scanned=%d generated=%d over%d=%d entries=%d lowerable=%d",
		r.Scanned, r.Generated, SoftLimit, r.Over, r.Entries, r.Lowerable)
	for _, v := range r.Violations {
		t.Error(v)
	}
}

// TestDebtHeaderStatesTheLimits ties the three-line rule at the top of the
// debt file to the constants: changing a limit without the text fails here.
func TestDebtHeaderStatesTheLimits(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", DebtFileName))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitN(string(data), "\n", 4)
	if len(lines) < 4 {
		t.Fatalf("%s has %d lines, want a three-line rule header first", DebtFileName, len(lines))
	}
	for i, l := range lines[:3] {
		if !strings.HasPrefix(l, "# ") {
			t.Errorf("line %d is not a comment line: %q", i+1, l)
		}
	}
	header := strings.Join(lines[:3], "\n")
	for _, want := range []string{strconv.Itoa(SoftLimit), strconv.Itoa(HardLimit), "legacy", "accepted", "generated"} {
		if !strings.Contains(header, want) {
			t.Errorf("the rule header does not mention %q:\n%s", want, header)
		}
	}
}
