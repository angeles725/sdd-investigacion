package parity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for rel, body := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// pair returns a pristine tree and an identical "after" tree.
func pair(t *testing.T, files map[string]string) (string, string) {
	t.Helper()
	base := t.TempDir()
	pristine, after := filepath.Join(base, "pristine"), filepath.Join(base, "after")
	for _, d := range []string{pristine, after} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		writeTree(t, d, files)
	}
	return pristine, after
}

func effectOf(t *testing.T, pristine, after string) string {
	t.Helper()
	b, err := treeEffect(pristine, after)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTreeEffect(t *testing.T) {
	files := map[string]string{"a.md": "alpha", "sub/b.md": "bravo", "sub/c.md": "charlie"}
	tests := []struct {
		name   string
		mutate func(t *testing.T, after string)
		want   []string // every substring must appear
		not    []string // none may appear
	}{
		{"untouched", func(*testing.T, string) {}, nil, []string{"a.md", "b.md"}},
		{"mtime only", func(t *testing.T, after string) {
			future := time.Now().Add(5 * time.Hour)
			if err := os.Chtimes(filepath.Join(after, "a.md"), future, future); err != nil {
				t.Fatal(err)
			}
		}, nil, []string{"a.md"}},
		{"added file", func(t *testing.T, after string) { writeTree(t, after, map[string]string{"new/d.md": "delta"}) },
			[]string{"added", "new", "new/d.md", `"delta"`}, nil},
		{"removed file", func(t *testing.T, after string) { os.Remove(filepath.Join(after, "sub", "b.md")) },
			[]string{"removed", "sub/b.md"}, []string{"c.md"}},
		{"modified content", func(t *testing.T, after string) {
			os.WriteFile(filepath.Join(after, "a.md"), []byte("ALPHA"), 0o644)
		}, []string{"modified", "a.md", `"ALPHA"`}, []string{"b.md"}},
		{"mode change", func(t *testing.T, after string) { os.Chmod(filepath.Join(after, "a.md"), 0o755) },
			[]string{"modified", "a.md", "mode 0644->0755"}, nil},
		{"symlink added", func(t *testing.T, after string) { os.Symlink("../outside", filepath.Join(after, "ln")) },
			[]string{"added", "symlink", "ln", `"../outside"`}, nil},
		{"type change file to dir", func(t *testing.T, after string) {
			os.Remove(filepath.Join(after, "a.md"))
			os.Mkdir(filepath.Join(after, "a.md"), 0o755)
		}, []string{"modified", "a.md", "type file->dir"}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pristine, after := pair(t, files)
			tt.mutate(t, after)
			got := effectOf(t, pristine, after)
			if len(tt.want) == 0 && got != "" {
				t.Fatalf("no content/mode/structure change means an empty effect, got %q", got)
			}
			for _, w := range tt.want {
				if !strings.Contains(got, w) {
					t.Errorf("effect lacks %q:\n%s", w, got)
				}
			}
			for _, n := range tt.not {
				if strings.Contains(got, n) {
					t.Errorf("effect should not mention %q:\n%s", n, got)
				}
			}
			if again := effectOf(t, pristine, after); again != got {
				t.Errorf("effect is not deterministic:\n%s\n--\n%s", got, again)
			}
		})
	}
}

func TestTreeEffectSymlinkTargetChange(t *testing.T) {
	pristine, after := pair(t, map[string]string{"f": "x"})
	os.Symlink("one", filepath.Join(pristine, "ln"))
	os.Symlink("two", filepath.Join(after, "ln"))
	got := effectOf(t, pristine, after)
	if !strings.Contains(got, "modified") || !strings.Contains(got, `link "one"->"two"`) {
		t.Fatalf("a changed symlink target must be reported:\n%s", got)
	}
}

func TestTreeEffectEmptyFileAndLargeContent(t *testing.T) {
	big := strings.Repeat("z", inlineContentMax+10)
	pristine, after := pair(t, map[string]string{"big": big, "e": ""})
	if got := effectOf(t, pristine, after); got != "" {
		t.Fatalf("untouched large/empty files: %q", got)
	}
	os.WriteFile(filepath.Join(after, "big"), []byte(big[:len(big)-1]+"Y"), 0o644)
	os.WriteFile(filepath.Join(after, "e"), []byte("n"), 0o644)
	got := effectOf(t, pristine, after)
	if !strings.Contains(got, "big") || !strings.Contains(got, "sha256=") || strings.Contains(got, big[:100]) {
		t.Fatalf("large content is shown as a digest, not inline:\n%s", got)
	}
	if !strings.Contains(got, `"n"`) {
		t.Fatalf("small content is shown inline:\n%s", got)
	}
	// A one-byte change in a large file must change the effect.
	os.WriteFile(filepath.Join(after, "big"), []byte(big[:len(big)-1]+"W"), 0o644)
	if got2 := effectOf(t, pristine, after); got2 == got {
		t.Fatal("two different large contents produced the same effect")
	}
}

func TestTreeEffectIsSortedByPath(t *testing.T) {
	pristine, after := pair(t, map[string]string{"keep": "k"})
	writeTree(t, after, map[string]string{"zz": "1", "aa": "2", "mm/x": "3"})
	got := effectOf(t, pristine, after)
	if !(strings.Index(got, "aa") < strings.Index(got, "mm") && strings.Index(got, "mm") < strings.Index(got, "zz")) {
		t.Fatalf("entries must be sorted by path:\n%s", got)
	}
}

func TestTreeEffectAbsentTreeIsAnError(t *testing.T) {
	pristine, _ := pair(t, map[string]string{"f": "x"})
	if _, err := treeEffect(pristine, filepath.Join(t.TempDir(), "gone")); err == nil {
		t.Fatal("a vanished scratch tree must be an error, not an empty effect")
	}
	if _, err := treeEffect(filepath.Join(t.TempDir(), "gone"), pristine); err == nil {
		t.Fatal("an absent pristine tree must be an error")
	}
}
