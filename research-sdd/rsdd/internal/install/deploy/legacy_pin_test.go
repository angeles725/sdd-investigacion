package deploy

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// frozenLegacy pins the sha256 of every frozen legacy script (copied byte-identical from research-sdd/install at the
// time slice S0a was cut). The oracle never changes: a later edit of the live script must not move the expectations,
// and an edit of a frozen copy must fail here before it can hide a behaviour change.
var frozenLegacy = map[string]string{
	"install/adapters.sh":             "3efa258b15553b12dd7797fd1503028d7f84909018cf8d1eb1f3f49383f24492",
	"install/research-sdd-install.sh": "5580b84210a2d36f434102c3fad0f15cd959f9d56dc9e3fb5a881e94f16ef629",
}

const legacyDir = "testdata/legacy"

func TestFrozenLegacyScriptsAreByteIdentical(t *testing.T) {
	if len(frozenLegacy) != 2 {
		t.Fatalf("the pin table must name both frozen scripts, has %d", len(frozenLegacy))
	}
	for rel, want := range frozenLegacy {
		b, err := os.ReadFile(filepath.Join(legacyDir, filepath.FromSlash(rel)))
		if err != nil {
			t.Fatalf("frozen script unreadable (an absent oracle proves nothing): %v", err)
		}
		sum := sha256.Sum256(b)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s drifted: sha256 %s, pinned %s", rel, got, want)
		}
	}
}
