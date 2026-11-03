package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The frozen legacy bytes the registry differential tests run (testdata/legacy/registry and lib/hook-emit.sh)
// are pinned by SHA256SUMS, so an edit to the oracle cannot go unnoticed. Updating a hash is a deliberate act.
func TestRegistryLegacyOracleIsPinned(t *testing.T) {
	sums, err := os.ReadFile(filepath.Join("testdata", "legacy", "registry", "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		want, rel, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 {
			t.Fatalf("malformed SHA256SUMS line %q", line)
		}
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", rel))
		if err != nil {
			t.Fatalf("pinned file missing: %v", err)
		}
		got := sha256.Sum256(b)
		if hex.EncodeToString(got[:]) != want {
			t.Errorf("%s changed: sha256 %x, pinned %s", rel, got, want)
		}
		n++
	}
	if n < 9 {
		t.Errorf("only %d files pinned; the oracle has 9 (script, hook, six libs, hook-emit)", n)
	}
}
