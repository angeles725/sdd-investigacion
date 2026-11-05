package block

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// The frozen legacy script and the two libraries it sourced before the port are the oracle of
// `rsdd verify block`. Their bytes are pinned: refreshing the oracle is a deliberate act (update the sums here and
// regenerate testdata/block-goldens.json with RSDD_UPDATE_GOLDENS=1), never a side effect.
func TestBlockLegacyBytesPinned(t *testing.T) {
	t.Parallel()
	for rel, want := range map[string]string{
		"verify-block.sh":         "04f063f264b7d521602884a9eaac383fd1aabd1fada5e77e9d8ef39c1bc7de20",
		"lib/block-files.sh":      "b5980b1e9e8c5e490e2a2f9dffe584ddec8add7a7e260adb4f1fe150abc869e3",
		"lib/scripts-manifest.sh": "05012785ce298bfca09190d891551f43b11464804d9ebaf275b9171bc9731bfc",
	} {
		raw, err := os.ReadFile(filepath.Join("testdata", "block-legacy", rel))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(raw)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Errorf("%s: sha256 %s, pinned %s", rel, got, want)
		}
	}
}
