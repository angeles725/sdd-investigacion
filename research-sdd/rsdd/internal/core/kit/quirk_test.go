package kit

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func withBehaviour(t *testing.T, q Quirks) {
	t.Helper()
	old := Behaviour
	Behaviour = q
	t.Cleanup(func() { Behaviour = old })
}

// F1: legacy bash row blanks. Pure accident: the real TARGETS.md has no row led by \v, \f or \r.
func TestQuirkF1RowBlanks(t *testing.T) {
	want := []string{"/after-cr", "/after-ff", "/after-vtab"}
	if got := PathsAll(targetCorpus["vtab-row"], rhEnv("")); !reflect.DeepEqual(got, want) {
		t.Fatalf("legacy: %q", got)
	}
	withBehaviour(t, GFMShaped)
	if got := PathsAll(targetCorpus["vtab-row"], rhEnv("")); len(got) != 0 {
		t.Fatalf("gfm-shaped must not read \\v \\f \\r led lines as rows: %q", got)
	}
	if got := PathsAll(targetCorpus["indented"], rhEnv("")); !reflect.DeepEqual(got, []string{"/spaces", "/tab"}) {
		t.Fatalf("space and tab stay valid: %q", got)
	}
}

// F5: legacy bash splits name-lookup rows on every pipe. Pure accident: no TARGETS.md row holds `\|`.
func TestQuirkF5EscapedPipeInNameCell(t *testing.T) {
	root := physical(t, t.TempDir())
	mkfiles(t, root, "p/retros/r.md")
	tgt := write(t, filepath.Join(root, "T.md"), "| 1 | a\\|b | `"+root+"/p` |\n")
	name := func() string {
		r, err := NameForRetro(tgt, filepath.Join(root, "p/retros/r.md"), rhEnv(root))
		if err != nil {
			t.Fatal(err)
		}
		return r.Name
	}
	if got := name(); got != "p" {
		t.Fatalf("legacy: the shifted columns fall back to the basename, got %q", got)
	}
	withBehaviour(t, GFMShaped)
	if got := name(); got != "a|b" {
		t.Fatalf("gfm-shaped honours the escaped pipe, got %q", got)
	}
}

// F7: legacy find without -type, and the .git ancestor test on the whole printed path. Pure accident.
func TestQuirkF7FindWithoutTypeFilter(t *testing.T) {
	dirNamed := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dirNamed, "RESEARCH-STATE-dir.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	under := filepath.Join(stateFixture(t, ".git/corpus/RESEARCH-STATE.md"), ".git", "corpus")
	count := func() (int, int) {
		a, err := ListStateFiles(dirNamed)
		if err != nil {
			t.Fatal(err)
		}
		b, err := ListStateFiles(under)
		if err != nil {
			t.Fatal(err)
		}
		return len(a), len(b)
	}
	if a, b := count(); a != 1 || b != 0 {
		t.Fatalf("legacy: dir-named listed=%d, under-.git listed=%d", a, b)
	}
	withBehaviour(t, GFMShaped)
	if a, b := count(); a != 0 || b != 1 {
		t.Fatalf("gfm-shaped: dir-named listed=%d, under-.git listed=%d", a, b)
	}
	// .git CONTENT stays excluded either way (that part is intended)
	in := stateFixture(t, ".git/RESEARCH-STATE.md")
	if got, _ := ListStateFiles(in); len(got) != 0 {
		t.Fatalf(".git content leaked: %q", got)
	}
}
