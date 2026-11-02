package kit

import (
	"os"
	"path/filepath"
	"testing"
)

// Guard-to-test table (lib/corpus-markers.sh):
//
//	INDEX.md / CATALOG.md at the root count ............ TestCorpusHasMarker/index, catalog
//	RESEARCH-STATE*.md counts, incl. -<focus> .......... TestCorpusHasMarker/state, focus-state
//	a *.template.md never counts ....................... TestCorpusHasMarker/template-only
//	no descent: a nested marker is not a marker ........ TestCorpusHasMarker/nested-only
//	missing or non-directory dir is false .............. TestCorpusHasMarker/missing, file-not-dir
//	a dangling INDEX.md link is not a marker ........... TestCorpusHasMarker/dangling-link
//	any candidate root wins ............................ TestCorpusMarkerPresent

type markerCase struct {
	name  string
	files []string // created empty under the case dir; "dir/" makes a directory
	want  bool
}

var markerCases = []markerCase{
	{"index", []string{"INDEX.md"}, true},
	{"catalog", []string{"CATALOG.md"}, true},
	{"state", []string{"RESEARCH-STATE.md"}, true},
	{"focus-state", []string{"RESEARCH-STATE-alpha.md"}, true},
	{"template-only", []string{"RESEARCH-STATE.template.md"}, false},
	{"template-and-real", []string{"RESEARCH-STATE.template.md", "RESEARCH-STATE-x.md"}, true},
	{"nested-only", []string{"corpus/INDEX.md"}, false},
	{"empty", nil, false},
	{"lowercase", []string{"index.md", "research-state.md"}, false},
	{"state-dir", []string{"RESEARCH-STATE.md/"}, true},
	{"other-md", []string{"README.md", "notes.md"}, false},
}

func buildMarkerCase(t *testing.T, root string, c markerCase) string {
	t.Helper()
	d := filepath.Join(root, c.name)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range c.files {
		if f[len(f)-1] == '/' {
			if err := os.MkdirAll(filepath.Join(d, f), 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		write(t, filepath.Join(d, f), "")
	}
	return d
}

func TestCorpusHasMarker(t *testing.T) {
	root := t.TempDir()
	for _, c := range markerCases {
		t.Run(c.name, func(t *testing.T) {
			if got := CorpusHasMarker(buildMarkerCase(t, root, c)); got != c.want {
				t.Errorf("CorpusHasMarker = %v, want %v", got, c.want)
			}
		})
	}
	t.Run("missing", func(t *testing.T) {
		if CorpusHasMarker(filepath.Join(root, "nope")) {
			t.Error("a missing directory carries no marker")
		}
	})
	t.Run("file-not-dir", func(t *testing.T) {
		f := write(t, filepath.Join(root, "afile"), "")
		if CorpusHasMarker(f) {
			t.Error("a regular file carries no marker")
		}
	})
	t.Run("dangling-link", func(t *testing.T) {
		d := filepath.Join(root, "dangling")
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, "gone"), filepath.Join(d, "INDEX.md")); err != nil {
			t.Fatal(err)
		}
		if CorpusHasMarker(d) {
			t.Error("a dangling INDEX.md link is not a marker (`[ -e ]` follows it)")
		}
	})
}

func TestCorpusMarkerPresent(t *testing.T) {
	root := t.TempDir()
	bare := buildMarkerCase(t, root, markerCase{"bare", nil, false})
	marked := buildMarkerCase(t, root, markerCase{"marked", []string{"INDEX.md"}, true})
	if CorpusMarkerPresent() {
		t.Error("no candidate roots: no marker")
	}
	if CorpusMarkerPresent(bare, filepath.Join(root, "missing")) {
		t.Error("no candidate carries a marker")
	}
	if !CorpusMarkerPresent(bare, marked) {
		t.Error("the second candidate carries a marker")
	}
	if !CorpusMarkerPresent(marked, bare) {
		t.Error("the first candidate carries a marker")
	}
}
