package console

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// legacySHA256 pins the frozen oracle: the bytes of toolbelt/serial-console.sh at origin/main 3c24631b, copied
// before the port (the live script is a shim now). The oracle never changes by accident: a later edit of the
// frozen copy fails here before it can hide a behaviour change, and the pin moves only with a recorded reason
// (go-port.md section 4.9 rule 7).
const (
	legacyPath   = "testdata/legacy/serial-console.sh"
	legacySHA256 = "88a21dbd9abcd5741190b0056531255b0c08d2531f255de28d880b298eb5d16a"
)

func TestFrozenLegacyScriptIsByteIdentical(t *testing.T) {
	b, err := os.ReadFile(legacyPath)
	if err != nil {
		t.Fatalf("frozen script unreadable (an absent oracle proves nothing): %v", err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != legacySHA256 {
		t.Errorf("%s drifted: sha256 %s, pinned %s", legacyPath, got, legacySHA256)
	}
}
