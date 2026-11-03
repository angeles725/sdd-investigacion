package sweep

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// The frozen oracles of the differential are the bytes of the two scripts at the commit before the port (kit issue #2360).
// SHA256SUMS pins them: editing a frozen script to make the differential pass fails here first.
func TestBreakthroughsLegacyIsPinned(t *testing.T) {
	sums, err := os.ReadFile("testdata/breakthroughs/legacy/SHA256SUMS")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(sums)), "\n")
	if len(lines) != 2 {
		t.Fatalf("SHA256SUMS pins %d files, want the 2 scripts", len(lines))
	}
	for _, l := range lines {
		sum, name, ok := strings.Cut(l, "  ")
		if !ok {
			t.Fatalf("bad SHA256SUMS line %q", l)
		}
		b, err := os.ReadFile("testdata/breakthroughs/legacy/" + name)
		if err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256(b)
		if got := hex.EncodeToString(h[:]); got != sum {
			t.Errorf("%s: sha256 %s, pinned %s", name, got, sum)
		}
	}
}
