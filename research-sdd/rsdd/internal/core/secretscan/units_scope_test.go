package secretscan

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCommittedScopeMatchesWholePath(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		path      string
		committed bool // committedInScope
		listed    bool // pathInScope (--files-from)
	}{
		{"notes.md", true, true},
		{"a/b/.env", true, true},
		{"a/.env.prod", true, true},
		{"a/credentials", true, true},
		{"a/credentials.txt", false, false},
		{"config.yaml", true, true},
		{"config.d/x.txt", true, false},
		{"app/config.old/x.txt", true, false},
		{"a/b/c/config.bak/d/e/x.txt", true, false},
		{"xconfig.d/x.txt", false, false},
		{"config/x.txt", false, false},
		{"a/config/x.txt", false, false},
		{"node_modules/config.d/x.txt", false, false},
		{"a/jadx/notes.md", false, false},
		{"a/jadx.md", true, true},
		{"sub/.git/notes.md", true, false},
		{"sub/.git/config.d/x.txt", true, false},
		{".git/notes.md", true, false},
		{"a/x.txt", false, false},
	} {
		if got := committedInScope(tc.path); got != tc.committed {
			t.Errorf("committedInScope(%q) = %v, want %v", tc.path, got, tc.committed)
		}
		if got := pathInScope(tc.path); got != tc.listed {
			t.Errorf("pathInScope(%q) = %v, want %v", tc.path, got, tc.listed)
		}
	}
}

// TestNarrowRootTieBreakIsByteOrder pins the corpus-root choice among equally deep directories: bytewise, so an
// upper-case name wins over a lower-case one. The legacy script ran `sort` in the caller's locale; the order is
// declared as an intended divergence because it is deterministic here.
func TestNarrowRootTieBreakIsByteOrder(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, d := range []string{"b", "B", "a_", "a-"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, d, "x-block1.md"), []byte("# b\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := narrowRoot(root, root); got != "B" {
		t.Errorf("narrowRoot = %q, want %q (byte order: B < a- < a_ < b)", got, "B")
	}
	if err := os.RemoveAll(filepath.Join(root, "B")); err != nil {
		t.Fatal(err)
	}
	if got := narrowRoot(root, root); got != "a-" {
		t.Errorf("narrowRoot = %q, want a-", got)
	}
}
