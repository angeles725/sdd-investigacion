package maint

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The kit-pr-pipeline fixtures the rdd tests read are a frozen copy (L114): the bash suites keep their own copy
// under toolbelt/tests/fixtures until they are deleted. Every file of the copy is pinned by
// testdata/legacy/kit-pr-pipeline.SHA256SUMS, and every pinned file must exist, so an edit, an addition or a
// removal is a deliberate act.
func TestKitPRPipelineFixturesArePinned(t *testing.T) {
	t.Parallel()
	root := filepath.Join("testdata", "legacy")
	sums, err := os.ReadFile(filepath.Join(root, "kit-pr-pipeline.SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	pinned := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		want, rel, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 {
			t.Fatalf("malformed SHA256SUMS line %q", line)
		}
		b, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("pinned file missing: %v", err)
		}
		if got := sha256.Sum256(b); hex.EncodeToString(got[:]) != want {
			t.Errorf("%s changed: sha256 %x, pinned %s", rel, got, want)
		}
		pinned[rel] = true
	}
	var unpinned []string
	err = filepath.WalkDir(filepath.Join(root, "kit-pr-pipeline"), func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		if rel, _ := filepath.Rel(root, p); !pinned[filepath.ToSlash(rel)] {
			unpinned = append(unpinned, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(unpinned) != 0 {
		t.Errorf("files in the frozen copy that SHA256SUMS does not pin: %v", unpinned)
	}
	if len(pinned) == 0 {
		t.Error("SHA256SUMS pins no file")
	}
}
