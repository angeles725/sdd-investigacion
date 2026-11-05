package sweep

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Teeth for the directory walks (kit issue #2592): each case below is the input a lived mutant of retrosfs.go
// changed the answer for.

func TestWalkRawDepthZeroListsOnlyTheRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	var seen []string
	walkRaw(root, 0, func(p string, _ fs.FileMode) { seen = append(seen, p) })
	if len(seen) != 1 || seen[0] != root {
		t.Errorf("maxDepth 0 lists the root alone, got %v", seen)
	}
	seen = nil
	walkRaw(root, 1, func(p string, _ fs.FileMode) { seen = append(seen, p) })
	if strings.Join(seen, " ") != root+" "+root+"/sub" {
		t.Errorf("maxDepth 1 lists the root and its entries, got %v", seen)
	}
}

func TestLowerASCIIBounds(t *testing.T) {
	// '@' and '[' sit just outside A-Z, '`' and '{' just outside a-z: only A and Z at the edges fold.
	if got, want := lowerASCII("AZ@[az`{É"), "az@[az`{É"; got != want {
		t.Errorf("lowerASCII = %q, want %q", got, want)
	}
}

func TestIsIndexNameTakesTheBasename(t *testing.T) {
	for p, want := range map[string]bool{
		"/index.md": true, "index.md": true, "INDEX.md": true, "/a/b/Index.md": true,
		"/a.md": false, "a.md": false, "/index/a.md": false, "/xindex": false,
	} {
		if got := isIndexName(p); got != want {
			t.Errorf("isIndexName(%q) = %v, want %v", p, got, want)
		}
	}
}
