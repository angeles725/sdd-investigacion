package stageissues

import (
	"os/exec"
	"testing"
)

// TestGolden runs every case of allCases() through the Go command and compares it with the behaviour recorded
// from the legacy script (testdata/golden, written by TestDifferential -update). It needs no legacy run, so it
// also runs under gremlins' -tags nodiff. The fake gh is a bash script, so a missing bash fails loudly.
func TestGolden(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("golden: bash not found in PATH (the fake gh is a bash script); the port is NOT checked in this run")
	}
	for _, c := range allCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			c = c.resolve(t)
			b := mkBox(t, c)
			if d := diffResult(readGolden(t, c.name), runGo(t, b, c)); d != "" {
				t.Errorf("differs from the recorded legacy behaviour:\n%s", d)
			}
		})
	}
}

// TestCaseNamesUnique guards the golden file naming: two cases must never share a file.
func TestCaseNamesUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range allCases() {
		if seen[goldenPath(c.name)] {
			t.Errorf("duplicate case name %q", c.name)
		}
		seen[goldenPath(c.name)] = true
	}
	if len(seen) == 0 {
		t.Fatal("no cases")
	}
}
