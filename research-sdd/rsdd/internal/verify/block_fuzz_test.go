//go:build unix && !nodiff

package verify

import (
	"os"
	"strconv"
	"testing"
)

// TestBlockDifferentialFuzz runs freshly generated blocks (seeds other than the recorded corpus) through the
// legacy script and the Go command, live. It is opt-in: RSDD_BLOCK_FUZZ_N sets the number of cases and
// RSDD_BLOCK_FUZZ_SEED the seed (default 1). The recorded corpus in blockCases() is the standing guard; this is
// the search for what it does not cover.
func TestBlockDifferentialFuzz(t *testing.T) {
	n, _ := strconv.Atoi(os.Getenv("RSDD_BLOCK_FUZZ_N"))
	if n <= 0 {
		t.Skip("RSDD_BLOCK_FUZZ_N not set: the opt-in fuzz differential does not run")
	}
	seed, err := strconv.ParseInt(os.Getenv("RSDD_BLOCK_FUZZ_SEED"), 10, 64)
	if err != nil {
		seed = 1
	}
	bad := 0
	for _, c := range genCasesSeed(seed, n, "fuzz") {
		want := runBlockLegacy(t, c)
		got := runBlockGo(t, c)
		if got != want {
			bad++
			t.Errorf("%s (seed %d) differs from the legacy script\nblock:\n%s\nlegacy rc=%d\n%s\n--- stderr: %q\n     go rc=%d\n%s\n--- stderr: %q",
				c.name, seed, c.files["c/kit-block9.md"], want.RC, want.Stdout, want.Stderr, got.RC, got.Stdout, got.Stderr)
			if bad >= 5 {
				t.Fatal("stopping after 5 differences")
			}
		}
	}
}
