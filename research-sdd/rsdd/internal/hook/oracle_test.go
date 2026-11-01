package hook

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// The frozen bash the differential tests use as their oracle must not drift: editing it would let a Go change and a
// bash change agree with each other. These are the sha256 of the files as frozen (U2.3a: half1; U2.3b, kit issue
// #2357: half2). driver.sh itself may grow modes; its hash is not pinned.
var oracleSums = map[string]string{
	"testdata/legacy/hook-wiring-half1.sh": "fbc86bcd1f2c283fe9295969ac3ecce5679add404b9491aa99110bb1572881ad",
	"testdata/legacy/hook-wiring-half2.sh": "15831786d98b4d97a8903544b63603244328be13053d33ad6b0e16cc468bd97b",
}

func TestFrozenOraclesAreUnchanged(t *testing.T) {
	for path, want := range oracleSums {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(b)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s changed: sha256 %s, frozen %s", path, got, want)
		}
	}
}
