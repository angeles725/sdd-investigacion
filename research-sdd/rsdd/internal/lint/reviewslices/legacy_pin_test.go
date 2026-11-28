package reviewslices

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// legacySHA pins the frozen oracle: the bytes of toolbelt/plan-review-slices.sh before the port (copied from
// origin/main 3c24631b). The live script is a shim now, so the oracle never moves with it, and an edit of the frozen
// copy fails here before it can hide a behaviour change. It moves only with a recorded reason.
const legacySHA = "baa93fe04aac2a3667452ffbff62b3e890a435df9a6279b09f04636e9ed53af3"

const legacyScript = "testdata/legacy/plan-review-slices.sh"

func TestFrozenLegacyScriptIsByteIdentical(t *testing.T) {
	b, err := os.ReadFile(legacyScript)
	if err != nil {
		t.Fatalf("frozen script unreadable (an absent oracle proves nothing): %v", err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != legacySHA {
		t.Errorf("%s drifted: sha256 %s, pinned %s", legacyScript, got, legacySHA)
	}
}
