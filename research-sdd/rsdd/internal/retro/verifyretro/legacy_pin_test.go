//go:build !nodiff

package verifyretro

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// The legacy script and the lib it sources are frozen under testdata/legacy: they are the oracle of the
// differential test, so an edit must be deliberate. Refreeze by copying the files from the toolbelt and updating
// the digests below in the same commit.
var legacyPins = map[string]string{
	"testdata/legacy/verify-retro.sh":      "ee90632a88e69097c2a9d291306f563b90c8e77bd7b574b42cf9bfd5c3b6094f",
	"testdata/legacy/lib/retro-grammar.sh": "e431f688f26956b74dbb510216dd2d84dbaee5344c1db8317451e2ec6a134b51",
}

func TestLegacyOracleIsFrozen(t *testing.T) {
	for path, want := range legacyPins {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		sum := sha256.Sum256(data)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s changed: sha256 %s, pinned %s", path, got, want)
		}
	}
}
