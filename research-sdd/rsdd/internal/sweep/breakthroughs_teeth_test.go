package sweep

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// Teeth for the breakthrough sweep (kit issue #2592).

func TestParentAndFileLeadAtTheStart(t *testing.T) {
	for in, want := range map[string]string{
		"BREAKTHROUGHS.md: c.md:1": "c.md:1", // the lead at index 0 is cut: one segment is left
		"BREAKTHROUGHS.md: a/b:2":  "a/b:2",
		"x/y/z":                    "y/z",
		"y/z":                      "y/z",
		"single":                   "single",
	} {
		if got := parentAndFile(in); got != want {
			t.Errorf("parentAndFile(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDriftPassReadsARelativePointerAgainstTheCaller(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "b-block1.md"), []byte("x\n> **Breakthrough:** y\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	var tot btTotals
	driftPass(&out, dir, []string{"b-block1.md:2"}, os.ReadFile, &tot)
	if out.Len() != 0 || tot.drift != 0 {
		t.Errorf("a relative pointer resolves below the caller's directory: drift=%d\n%s", tot.drift, out.String())
	}
	// With no caller directory the pointer stays relative to the process: the file is not there.
	out.Reset()
	tot = btTotals{}
	driftPass(&out, "", []string{"b-block1.md:2"}, os.ReadFile, &tot)
	if want := "WARN: drift — indexed block file no longer exists: b-block1.md (from BREAKTHROUGHS.md)\n"; out.String() != want || tot.drift != 1 {
		t.Errorf("got %q drift=%d, want %q", out.String(), tot.drift, want)
	}
}
