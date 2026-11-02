package verify

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Guard-to-test table (registryfs.go and the small helpers of registry.go):
//
//	find without -H/-L: symlinks not followed, depth bound .. TestFindWalk
//	basename / dirname of the shell, no path cleaning ...... TestBashBasenameDirname
//	find -path / -iname globs ............................... TestRetroGlobs
//	retro opt-out reader (leading block, BOM, full line) .... TestRetroIsExcluded
//	awk length(): bytes or characters by locale ............. TestAwkLength
//	awk comparison against RSDD_ROW_MAXLEN .................. TestCellLonger
//	tolerance tests false on a non-integer tol .............. TestTolBoundaries
//	jq envelope escaping ..................................... TestEnvelopeEscaping

func TestFindWalk(t *testing.T) {
	root := t.TempDir()
	for _, f := range []string{"a.md", "d1/b.md", "d1/d2/c.md", "d1/d2/d3/d.md", "d1/d2/d3/d4/e.md", ".hid.md"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(root, "d1"), filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	collect := func(start string, depth int) []string {
		var got []string
		findWalk(start, depth, func(p string, _ fs.FileMode) { got = append(got, strings.TrimPrefix(p, root)) })
		sort.Strings(got)
		return got
	}
	if got := strings.Join(collect(root, 0), ","); got != "" { // only the root itself, which TrimPrefix empties
		t.Errorf("maxdepth 0: %q", got)
	}
	if got := strings.Join(collect(root, 1), ","); got != ",/.hid.md,/a.md,/d1,/link" {
		t.Errorf("maxdepth 1: %q", got)
	}
	if got := strings.Join(collect(root, 3), ","); got != ",/.hid.md,/a.md,/d1,/d1/b.md,/d1/d2,/d1/d2/c.md,/d1/d2/d3,/link" {
		t.Errorf("maxdepth 3 (the link is not followed): %q", got)
	}
	if got := collect(filepath.Join(root, "link"), 3); len(got) != 1 {
		t.Errorf("a symlinked start is visited, not descended: %v", got)
	}
	if got := collect(root+"/", 1); len(got) == 0 || strings.Contains(strings.Join(got, ","), "//") {
		t.Errorf("a start with a trailing slash must not double it: %v", got)
	}
	if got := collect(filepath.Join(root, "missing"), 3); got != nil {
		t.Errorf("a missing start yields nothing: %v", got)
	}
	if md := listMarkdown(root); len(md) != 2 { // a.md and .hid.md; the symlinked directory is not a file
		t.Errorf("listMarkdown: %v", md)
	}
	if err := os.Symlink(filepath.Join(root, "a.md"), filepath.Join(root, "ln.md")); err != nil {
		t.Fatal(err)
	}
	if md := listMarkdown(root); len(md) != 2 {
		t.Errorf("a symlink named *.md is not a regular file (find -type f): %v", md)
	}
}

func TestBashBasenameDirname(t *testing.T) {
	for _, c := range []struct{ in, base, dir string }{
		{"/a/b/c", "c", "/a/b"}, {"/a/b/c/", "c", "/a/b"}, {"/a//b//", "b", "/a"}, {"c", "c", "."},
		{"/", "/", "/"}, {"//", "/", "/"}, {"", "", "."}, {"/c", "c", "/"}, {"a/./b", "b", "a/."}, {"a/../b", "b", "a/.."},
	} {
		if got := bashBasename(c.in); got != c.base {
			t.Errorf("basename(%q) = %q, want %q", c.in, got, c.base)
		}
		if got := bashDirname(c.in); got != c.dir {
			t.Errorf("dirname(%q) = %q, want %q", c.in, got, c.dir)
		}
	}
}

func TestRetroGlobs(t *testing.T) {
	for _, c := range []struct {
		p                     string
		retros, index, hidden bool
	}{
		{"/x/retros/a.md", true, false, false},
		{"/x/retros/.md", true, false, false},
		{"/x/retros/a.txt", false, false, false},
		{"/x/retros/", false, false, false},
		{"/x/retros.md", false, false, false},
		{"/x/retros/sub/dir/a.md", true, false, false},
		{"/x/retros/INDEX.md", true, true, false},
		{"/x/retros/my-Index-file.md", true, true, false},
		{"/x/retros/index.md.bak", false, false, false},
		{"/x/retros/indexmd", false, false, false},
	} {
		if got := globRetros(c.p); got != c.retros {
			t.Errorf("globRetros(%q) = %v", c.p, got)
		}
		if got := globIndexMD(bashBasename(c.p)); got != c.index {
			t.Errorf("globIndexMD(%q) = %v", c.p, got)
		}
	}
	root := t.TempDir()
	for _, f := range []string{"retros/a.md", "retros/index.md", ".git/retros/g.md", "x/y/retros/b.md", "x/y/z/retros/deep.md"} {
		p := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	rel := func(xs []string) string {
		for i := range xs {
			xs[i] = strings.TrimPrefix(xs[i], root+"/")
		}
		sort.Strings(xs)
		return strings.Join(xs, ",")
	}
	if got := rel(retroEntries(root, true)); got != "retros/a.md,x/y/retros/b.md" {
		t.Errorf("retroEntries(skipIndex): %s", got)
	}
	if got := rel(retroEntries(root, false)); got != "retros/a.md,retros/index.md,x/y/retros/b.md" {
		t.Errorf("retroEntries: %s", got)
	}
}

func TestRetroIsExcluded(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]bool{
		"<!-- kit-retro: exclude -->\n# r\n":                  true,
		"<!--kit-retro:exclude-->":                            true,
		"\n\n  <!--  KIT-RETRO: EXCLUDE  -->  \r\n# r":        true,
		"\xef\xbb\xbf<!-- kit-retro: exclude -->\n":           true,
		"<!-- other -->\n<!-- kit-retro: exclude -->\n":       true,
		"<!-- other -->\ntext\n<!-- kit-retro: exclude -->\n": false,
		"# heading\n<!-- kit-retro: exclude -->\n":            false,
		"<!-- kit-retro: exclude --> and more\n":              false,
		"<!-- kit-retro: include -->\n":                       false,
		"":                                                    false,
	}
	i := 0
	for body, want := range cases {
		i++
		f := filepath.Join(dir, strings.Repeat("r", i)+".md")
		if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := retroIsExcluded(f); got != want {
			t.Errorf("retroIsExcluded(%q) = %v, want %v", body, got, want)
		}
	}
	if retroIsExcluded("") || retroIsExcluded(filepath.Join(dir, "missing.md")) || retroIsExcluded(dir) {
		t.Error("empty, missing and non-regular paths are not excluded")
	}
}

func TestAwkLength(t *testing.T) {
	for _, c := range []struct {
		env  map[string]string
		want int
	}{
		{map[string]string{"LC_ALL": "C"}, 4}, {map[string]string{"LC_ALL": "en_US.UTF-8"}, 2}, {map[string]string{"LC_ALL": "C.utf8"}, 2},
		{map[string]string{"LANG": "C.UTF-8"}, 2}, {map[string]string{"LC_CTYPE": "UTF-8", "LANG": "C"}, 2},
		{map[string]string{"LC_ALL": "C", "LANG": "UTF-8"}, 4}, {map[string]string{}, 4},
	} {
		r := &registry{}
		r.s.Env = func(k string) string { return c.env[k] }
		if got := r.awkLength("éé"); got != c.want {
			t.Errorf("awkLength under %v = %d, want %d", c.env, got, c.want)
		}
	}
}

func TestCellLonger(t *testing.T) {
	for _, c := range []struct {
		n    int
		max  string
		want bool
	}{
		{30, "25", true}, {25, "25", false}, {26, " 25 ", true}, {5, "4.5", true}, {4, "4.5", false}, {200, "2e2", false}, {201, "2e2", true},
		{10, "abc", false}, // text comparison: "10" < "abc"
		{5, "10x", true},   // "5" > "10x" as text
	} {
		if got := cellLonger(c.n, c.max); got != c.want {
			t.Errorf("cellLonger(%d, %q) = %v, want %v", c.n, c.max, got, c.want)
		}
	}
}

func TestTolBoundaries(t *testing.T) {
	r := &registry{tol: "2"}
	if r.gtTol(2) || !r.gtTol(3) || !r.leTol(2) || r.leTol(3) {
		t.Error("tol 2: gt and le must meet at the boundary")
	}
	r.tol = "abc"
	if r.gtTol(100) || r.leTol(0) {
		t.Error("a non-integer tol makes both tests false, as `[` does")
	}
	r.tol = " 5 "
	if !r.gtTol(6) {
		t.Error("surrounding blanks are tolerated")
	}
	if leadingInt("007") != 7 || leadingInt("99999999999999999999") <= 0 {
		t.Error("leadingInt: decimal parse, clamped on overflow")
	}
	if absDiff(3, 8) != 5 || absDiff(8, 3) != 5 {
		t.Error("absDiff")
	}
}

func TestEnvelopeEscaping(t *testing.T) {
	out := registryEnvelope(false, regCounts{}, []regItem{{"k", "WARN", "t\"x", "a\\b\x01\x7f é\ttab"}})
	want(t, out, `"target": "t\"x"`, `"message": "a\\b\u0001\u007f é\ttab"`)
	out = registryEnvelope(true, regCounts{Targets: 3}, []regItem{{"k", "s", "t", "m"}})
	want(t, out, `"state": "absent-input"`, `"items": []`, `"targets": 3`)
	wantNot(t, out, `"kind"`)
}
