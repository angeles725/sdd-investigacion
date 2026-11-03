//go:build !nodiff

package stage

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// The legacy script and the libs it sourced are frozen under testdata/legacy: they are the oracle of the
// differential test, so an edit must be deliberate. Refreeze by copying the files from the toolbelt and updating
// the digests below in the same commit.
var legacyPins = map[string]string{
	"testdata/legacy/stage-retro.sh":      "db80ca8155976e9951c7c77853e60cbe16a62cef12b2045767314c463dc6b1eb",
	"testdata/legacy/lib/retro-status.sh": "d5c1cccdffdd9944ad3b8ab55fd509b8b1b7914ef07b59dda3da48219857cf40",
	"testdata/legacy/lib/target-paths.sh": "513ee2d7b46d363a8db08b86c3b3672e13dcc0618b4c1865b4d5978227d9dadf",
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
