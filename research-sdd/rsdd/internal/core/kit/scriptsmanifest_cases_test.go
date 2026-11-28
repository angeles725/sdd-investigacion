package kit

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

// The cases the bash suite of lib/scripts-manifest.sh carried and the tests in scriptsmanifest_test.go do not:
// a nested cell, the list edges, "//" in the manifest path, a manifest with no valid row, a real file outside
// the target, an empty argument, and sha cells one or two digits off 64. The helper and its suite are deleted;
// this file is where those rules are pinned now.

// manifestAt writes body as <root>/sources/probes/b1/SCRIPTS-MANIFEST.md and returns the target and the path.
func manifestAt(t *testing.T, body string) (target, mf string) {
	t.Helper()
	target = filepath.Join(t.TempDir(), "target")
	dir := filepath.Join(target, "sources", "probes", "b1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mf = filepath.Join(dir, "SCRIPTS-MANIFEST.md")
	if err := os.WriteFile(mf, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return target, mf
}

// pair is the two rows one valid line yields: the resolved cell, then <manifest dir>/<basename>.
func pair(resolved, base, sha string) []string {
	return []string{resolved + "\t" + sha, "sources/probes/b1/" + base + "\t" + sha}
}

func TestScriptsManifestRowsCells(t *testing.T) {
	h := strings.Repeat("0", 64)
	for _, tc := range []struct {
		name, body string
		want       []string
	}{
		{"a bare cell resolves against the manifest's directory", "| `a.sh` | " + h + " | x |\n",
			pair("sources/probes/b1/a.sh", "a.sh", h)},
		{"a nested cell keeps its sub-directory and also lists by basename", "| `sub/c.sh` | " + h + " | x |\n",
			pair("sources/probes/b1/sub/c.sh", "c.sh", h)},
		{"first, middle and unterminated last rows are all read",
			"| `first.sh` | " + h + " | x |\n| garbage |\n| `mid.sh` | " + h + " | x |\nprose line\n| `last.sh` | " + h + " | x |",
			append(append(pair("sources/probes/b1/first.sh", "first.sh", h), pair("sources/probes/b1/mid.sh", "mid.sh", h)...),
				pair("sources/probes/b1/last.sh", "last.sh", h)...)},
		{"a single row without a final newline is read", "| `only.sh` | " + h + " | x |",
			pair("sources/probes/b1/only.sh", "only.sh", h)},
		{"no valid row is an empty list, not a failure", "just prose, no table\n", nil},
		{"a sha cell of 62, 63, 65 or 66 hex digits, TODO or a dash lists nothing",
			"| `a.sh` | " + h[:62] + " | x |\n| `b.sh` | " + h[:63] + " | x |\n| `c.sh` | " + h + "0 | x |\n| `d.sh` | " + h + "00 | x |\n" +
				"| `todo.sh` | TODO | x |\n| `dash.sh` | - | x |\n", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			target, mf := manifestAt(t, tc.body)
			got, ok := ScriptsManifestRows(fsview.View{Cwd: target}, target, mf)
			if !ok || !reflect.DeepEqual(got, tc.want) {
				t.Errorf("rows = %q ok=%v, want %q ok=true", got, ok, tc.want)
			}
		})
	}
}

func TestScriptsManifestRowsPathForms(t *testing.T) {
	h := strings.Repeat("0", 64)
	target, mf := manifestAt(t, "| `only.sh` | "+h+" | x |\n")
	v := fsview.View{Cwd: target}
	want := pair("sources/probes/b1/only.sh", "only.sh", h)

	doubled := filepath.Dir(mf) + "//" + filepath.Base(mf)
	if got, ok := ScriptsManifestRows(v, target+"//", doubled); !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("trailing-slash target with // in the manifest path: rows = %q ok=%v, want %q", got, ok, want)
	}

	outside := filepath.Join(filepath.Dir(target), "outside.md")
	if err := os.WriteFile(outside, []byte("| `x.sh` | "+h+" | x |\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, ok := ScriptsManifestRows(v, target, outside); ok || got != nil {
		t.Errorf("a readable manifest outside the target: rows = %q ok=%v, want none and ok=false", got, ok)
	}
	if got, ok := ScriptsManifestRows(v, "", mf); ok || got != nil {
		t.Errorf("an empty target: rows = %q ok=%v, want none and ok=false", got, ok)
	}
	if got, ok := ScriptsManifestRows(v, target, ""); ok || got != nil {
		t.Errorf("an empty manifest path: rows = %q ok=%v, want none and ok=false", got, ok)
	}
}
