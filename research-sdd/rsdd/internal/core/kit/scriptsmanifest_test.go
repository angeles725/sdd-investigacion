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

// The row rules at their edges: a line holding only the first cell (no sha cell at all, so the cell index is one past
// the split) and a lone `|` yield no row and no panic; a sha cell is 64 hex digits in either case, and one non-hex
// character, whatever side of a hex range it sits on, rejects the row.
func TestScriptsManifestRowsEdges(t *testing.T) {
	root := t.TempDir()
	mf := filepath.Join(root, "SCRIPTS-MANIFEST.md")
	ok64 := "0123456789abcdefABCDEF" + strings.Repeat("9", 42)
	var src strings.Builder
	src.WriteString("|only.sh\n|\n| good.sh | " + ok64 + " |\n")
	for _, c := range []string{"/", ":", "@", "G", "`g", "g", "-"} {
		src.WriteString("| bad" + c + ".sh | " + strings.Repeat("a", 63) + c[len(c)-1:] + " |\n")
	}
	if err := os.WriteFile(mf, []byte(src.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	got, ok := ScriptsManifestRows(fsview.View{Cwd: root}, root, mf)
	// One valid line gives TWO rows: the resolved cell (<manifest dir>/good.sh) and <manifest dir>/<basename>. A manifest
	// at the target root has no "/" in its target-relative path, so its dir stays the whole path, as ${md%/*} does.
	resolved, byBase := "SCRIPTS-MANIFEST.md/good.sh", "SCRIPTS-MANIFEST.md/good.sh"
	want := []string{resolved + "\t" + strings.ToLower(ok64), byBase + "\t" + strings.ToLower(ok64)}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("rows = %q ok=%v, want %q", got, ok, want)
	}
}
