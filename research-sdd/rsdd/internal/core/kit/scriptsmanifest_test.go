package kit

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

func TestScriptsManifestRows(t *testing.T) {
	root := t.TempDir()
	sha := strings.Repeat("A", 64)
	dir := filepath.Join(root, "sources", "probes", "x")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mf := filepath.Join(dir, "SCRIPTS-MANIFEST.md")
	src := "| script | sha |\n|---|---|\n| `./run.sh` | `" + sha + "` |\n| sources/probes/y/z.sh | " + sha + " |\n| bad.sh | abc |\n"
	if err := os.WriteFile(mf, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	lo := strings.ToLower(sha)
	v := fsview.View{Cwd: root}
	got, ok := ScriptsManifestRows(v, root+"//", mf)
	want := []string{
		"sources/probes/x/run.sh\t" + lo, "sources/probes/x/run.sh\t" + lo,
		"sources/probes/y/z.sh\t" + lo, "sources/probes/x/z.sh\t" + lo,
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("rows = %q ok=%v, want %q", got, ok, want)
	}
	if _, ok := ScriptsManifestRows(v, root, filepath.Join(root, "missing.md")); ok {
		t.Error("an absent manifest must be ok=false")
	}
	if _, ok := ScriptsManifestRows(v, filepath.Join(root, "sources"), mf+"x"); ok {
		t.Error("a manifest outside the target must be ok=false")
	}
}
