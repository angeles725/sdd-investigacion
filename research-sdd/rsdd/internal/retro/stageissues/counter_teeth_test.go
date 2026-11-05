package stageissues

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Mutation-killing unit tests of counter.go (kit issue #2592). They call the helpers directly, carry no build tag
// and run no bash, so the -tags nodiff mutation run executes them.

func touch(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("# state\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func realTemp(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestStateFilesMaxDepth(t *testing.T) {
	root := realTemp(t)
	root1 := filepath.Join(root, "RESEARCH-STATE.md")
	root3 := filepath.Join(root, "a", "b", "RESEARCH-STATE-x.md")
	touch(t, root1)
	touch(t, root3)
	touch(t, filepath.Join(root, "a", "b", "c", "RESEARCH-STATE-four.md")) // find -maxdepth 3 stops above it
	got := stateFiles(root)
	if len(got) != 2 || got[0] != root1 || got[1] != root3 {
		t.Errorf("stateFiles = %q, want [%q %q]", got, root1, root3)
	}
}

func TestCoverLinesFocusAtStartOfValue(t *testing.T) {
	got := coverLines([]string{"covers_through: B7 focus=alpha", "covers_through: B8"})
	if len(got) != 2 || got[0].n != "7" || got[0].slug != "alpha" || got[1].n != "8" || got[1].slug != "-" {
		t.Errorf("coverLines = %+v", got)
	}
}

func TestPhysDir(t *testing.T) {
	root := realTemp(t)
	if err := os.MkdirAll(filepath.Join(root, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	touch(t, filepath.Join(root, "file"))
	a := &app{s: cli.Stdio{Cwd: root}}
	for _, c := range []struct {
		in   string
		want string
		ok   bool
	}{
		{filepath.Join(root, "link"), filepath.Join(root, "real"), true},
		{"link", filepath.Join(root, "real"), true}, // relative: joined to the caller's cwd
		{filepath.Join(root, "missing"), "", false},
		{filepath.Join(root, "file"), "", false}, // a file is not a directory
	} {
		got, ok := a.physDir(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("physDir(%q) = %q, %v; want %q, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

// counterApp is an app whose retro lives in <root>/<retroRel> and whose TARGETS.md registers the given paths.
func counterApp(t *testing.T, root, retroRel string, registered ...string) *app {
	t.Helper()
	targets := "| # | Target | Path |\n|---|---|---|\n"
	for i, p := range registered {
		targets += "| " + string(rune('1'+i)) + " | t | `" + p + "` |\n"
	}
	md := filepath.Join(root, "TARGETS.md")
	if err := os.WriteFile(md, []byte(targets), 0o644); err != nil {
		t.Fatal(err)
	}
	retro := filepath.Join(root, retroRel)
	touch(t, retro)
	return &app{
		s:         cli.Stdio{Cwd: root, Env: func(string) string { return "" }},
		retro:     retro,
		targetsMD: md,
		targetDir: "fallback-target-dir",
	}
}

func TestCounterRootIsTheNearestRegisteredAncestor(t *testing.T) {
	root := realTemp(t)
	outer := filepath.Join(root, "corpus")
	inner := filepath.Join(outer, "sub")
	other := filepath.Join(root, "other")
	for _, d := range []string{inner, other} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	missing := filepath.Join(root, "gone")
	for _, order := range [][]string{{outer, inner}, {inner, outer}} {
		a := counterApp(t, root, "corpus/sub/retros/r.md", append([]string{other, missing}, order...)...)
		if got := a.counterRoot(); got != inner {
			t.Errorf("registered %q: counterRoot = %q, want the longest ancestor %q", order, got, inner)
		}
	}
	a := counterApp(t, root, "corpus/retros/r.md", outer, inner, other)
	if got := a.counterRoot(); got != outer {
		t.Errorf("counterRoot = %q, want %q", got, outer)
	}
}

func TestCounterRootFallsBackToTheTargetDir(t *testing.T) {
	root := realTemp(t)
	other := filepath.Join(root, "other")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	// no registered ancestor
	a := counterApp(t, root, "x/retros/r.md", other)
	if got := a.counterRoot(); got != "fallback-target-dir" {
		t.Errorf("unregistered retro: counterRoot = %q", got)
	}
	// a sibling whose name only shares a prefix is not an ancestor
	pre := filepath.Join(root, "x-more")
	if err := os.MkdirAll(pre, 0o755); err != nil {
		t.Fatal(err)
	}
	a = counterApp(t, root, "x/retros/r.md", pre)
	if got := a.counterRoot(); got != "fallback-target-dir" {
		t.Errorf("prefix-only sibling: counterRoot = %q", got)
	}
	// TARGETS.md unreadable
	a = counterApp(t, root, "x/retros/r.md", root)
	a.targetsMD = filepath.Join(root, "no-such-targets.md")
	if got := a.counterRoot(); got != "fallback-target-dir" {
		t.Errorf("missing TARGETS.md: counterRoot = %q", got)
	}
	// retro directory gone
	a = counterApp(t, root, "x/retros/r.md", root)
	a.retro = filepath.Join(root, "gone", "r.md")
	if got := a.counterRoot(); got != "fallback-target-dir" {
		t.Errorf("missing retro dir: counterRoot = %q", got)
	}
}

func TestCounterRootAbsolutisesARelativeRetro(t *testing.T) {
	root := realTemp(t)
	a := counterApp(t, root, "corpus/retros/r.md", filepath.Join(root, "corpus"))
	if err := os.MkdirAll(filepath.Join(root, "corpus"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	a.retro = filepath.Join("corpus", "retros", "r.md")
	if got, want := a.counterRoot(), filepath.Join(root, "corpus"); got != want {
		t.Errorf("relative retro: counterRoot = %q, want %q", got, want)
	}
}

// A retro with one valid line and nothing else must not print the "absent" note; one with no line must.
func TestCounterResetAbsentNote(t *testing.T) {
	root := realTemp(t)
	touch(t, filepath.Join(root, "RESEARCH-STATE.md"))
	for _, c := range []struct {
		raw        []string
		wantOut    string
		wantStderr string
	}{
		{[]string{"covers_through: B7"}, "proposed-reset: blocks_since_retro: 0 in RESEARCH-STATE.md (retro covers_through B7; set it by hand only if no newer block exists — propose-never-apply)\n", ""},
		{[]string{"nothing"}, "", "note: covers_through: absent in r.md — no blocks_since_retro reset proposed\n"},
	} {
		a := counterApp(t, root, "retros/r.md", root)
		var out, errb bytes.Buffer
		a.s.Out, a.s.Err = &out, &errb
		a.doc = &retrogrammar.Doc{Raw: c.raw}
		a.printCounterReset()
		if out.String() != c.wantOut || errb.String() != c.wantStderr {
			t.Errorf("%q: stdout %q stderr %q; want %q %q", c.raw, out.String(), errb.String(), c.wantOut, c.wantStderr)
		}
	}
}
