package sweep

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// The frozen oracle of the differential is the bytes of sweep-all.sh at the commit before the port (kit issue
// #2664). SHA256SUMS pins it: editing the frozen script to make the differential pass fails here first.
func TestAllLegacyIsPinned(t *testing.T) {
	sums, err := os.ReadFile("testdata/all/legacy/SHA256SUMS")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(sums)), "\n")
	if len(lines) != 1 {
		t.Fatalf("SHA256SUMS pins %d files, want the 1 script", len(lines))
	}
	sum, name, ok := strings.Cut(lines[0], "  ")
	if !ok || name != "sweep-all.sh" {
		t.Fatalf("bad SHA256SUMS line %q", lines[0])
	}
	b, err := os.ReadFile("testdata/all/legacy/" + name)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(b)
	if got := hex.EncodeToString(h[:]); got != sum {
		t.Errorf("%s: sha256 %s, pinned %s", name, got, sum)
	}
}
