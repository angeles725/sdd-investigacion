package sizecheck

import (
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestParseFailuresAndValues(t *testing.T) {
	for _, c := range []struct {
		args []string
		why  string // "" = accepted
		fmt  string // the format of the degraded document
		use  bool
	}{
		{[]string{"--base", "b"}, "", "", false},
		{nil, "--base is required", "report", true},
		{[]string{"--base"}, "--base needs a value", "report", false},
		{[]string{"--format", "json", "--base"}, "--base needs a value", "json", false},
		{[]string{"--format", "json", "--head"}, "--head needs a value", "json", false},
		{[]string{"--format"}, "--format needs a value", "report", false},
		{[]string{"--bogus"}, "unknown argument: --bogus", "report", true},
		{[]string{"--format", "json", "--bogus"}, "unknown argument: --bogus", "json", true},
		{[]string{"--format", "xml", "--bogus"}, "unknown argument: --bogus", "xml", true},
		{[]string{"--base", "b", "--format", "xml"}, "--format must be report or json", "report", false},
		{[]string{"--base", "b", "--budget", "0"}, "--budget must be a positive integer: 0", "report", false},
		{[]string{"--base", "b", "--budget", "007x"}, "--budget must be a positive integer: 007x", "report", false},
		{[]string{"--base", "b", "--budget", "1234567890"}, "--budget must be a positive integer of at most 9 digits: 1234567890", "report", false},
		{[]string{"--base", "b", "--budget", "123456789"}, "", "", false},
		{[]string{"--base", "b", "--hard-limit", "-1"}, "--hard-limit must be a positive integer: -1", "report", false},
		{[]string{"--base", "b", "--hard-limit", "1234567890"}, "--hard-limit must be a positive integer of at most 9 digits: 1234567890", "report", false},
		{[]string{"--base", "b", "--budget", "10", "--hard-limit", "9"}, "--hard-limit (9) must be >= --budget (10)", "report", false},
		{[]string{"--base", "b", "--hard-limit", "0"}, "--hard-limit (0) must be >= --budget (400)", "report", false},
		{[]string{"--base", "b", "--budget", "10", "--hard-limit", "10"}, "", "", false},
		{[]string{"--base", "", "--format", "json"}, "--base is required", "json", true},
	} {
		_, f := parse(c.args)
		switch {
		case f == nil && c.why != "":
			t.Errorf("%v accepted, want %q", c.args, c.why)
		case f != nil && (f.why != c.why || f.format != c.fmt || f.showUsage != c.use):
			t.Errorf("%v: %+v, want why=%q format=%q usage=%v", c.args, *f, c.why, c.fmt, c.use)
		}
	}
	o, _ := parse([]string{"--base", "B", "--head", "H", "--budget", "007", "--strict", "--format", "json"})
	if o.base != "B" || o.head != "H" || o.budget != 7 || o.hard != 14 || !o.strict || o.format != "json" {
		t.Errorf("%+v", o)
	}
	if o, f := parse([]string{"-h", "--bogus"}); f != nil || !o.help {
		t.Errorf("help wins over a later fault: %+v %v", o, f)
	}
	if o, _ := parse([]string{"--base", "b"}); o.head != "HEAD" || o.budget != 400 || o.hard != 800 || o.format != "report" || o.strict {
		t.Errorf("defaults: %+v", o)
	}
}

func TestParseNumstatEdges(t *testing.T) {
	es, why := parseNumstat("1\t2\ta.txt\x00-\t-\tb.bin\x003\t4\t\x00old.txt\x00new.txt\x005\t6\tlast.txt\x00")
	want := []entry{{"1", "2", "a.txt", ""}, {"-", "-", "b.bin", ""}, {"3", "4", "new.txt", "old.txt"}, {"5", "6", "last.txt", ""}}
	if why != "" || !reflect.DeepEqual(es, want) {
		t.Errorf("%v %q", es, why)
	}
	if es, why = parseNumstat(""); es != nil || why != "" {
		t.Errorf("empty: %v %q", es, why)
	}
	// a rename in the last position, and the single record
	if es, why = parseNumstat("0\t0\t\x00a\x00b\x00"); why != "" || len(es) != 1 || es[0].old != "a" || es[0].path != "b" {
		t.Errorf("single rename: %v %q", es, why)
	}
	// an unterminated tail is dropped, as the bash read loop never delivered it
	if es, _ = parseNumstat("1\t1\ta\x002\t2\tb"); len(es) != 1 {
		t.Errorf("unterminated tail: %v", es)
	}
	for _, c := range []struct{ in, why string }{
		{"1\t1\t\x00old\x00", "malformed rename record in numstat"},
		{"1\t1\t\x00old\x00\x00", "malformed rename record in numstat"},
		{"1\t1\t\x00", "malformed rename record in numstat"},
		{"1\t1\ta\x01b\x00", "unsupported path (control character: tab, newline, CR...) in diff"},
		{"1\t1\ta\x7f\x00", "unsupported path (control character: tab, newline, CR...) in diff"},
		{"1\t1\t\x00ol\x01d\x00new\x00", "unsupported path (control character: tab, newline, CR...) in diff"},
		{"x\t1\ta\x00", "malformed numstat record for a"},
		{"1\t\ta\x00", "malformed numstat record for a"},
	} {
		if _, why := parseNumstat(c.in); why != c.why {
			t.Errorf("%q: %q, want %q", c.in, why, c.why)
		}
	}
	if es, why = parseNumstat("1\t1\tcaf\xc3\xa9\x00"); why != "" || es[0].path != "café" {
		t.Errorf("bytes above 0x7f are not control characters: %v %q", es, why)
	}
}

func TestExcluded(t *testing.T) {
	f := "research-sdd/toolbelt/tests/fixtures/"
	for p, want := range map[string]bool{
		f + "a.json": true, f + "a.sh": false, f + "d/a.py": false, f + "d/a.mjs": false, f + "a.yml": true, f + "d.sh/x": true,
		f + ".sh": false, "research-sdd/toolbelt/tests/a.json": false, "x.lock": true, "d/Cargo.lock": true, "go.sum": true, "a/go.sum": true,
		"package-lock.json": true, "a/package-lock.json": true, "pnpm-lock.yaml": true, "a/pnpm-lock.yaml": true, "xgo.sum": false,
		"lock": false, "a.lock.txt": false, "research-sdd/toolbelt/tests/fixture/a.json": false,
	} {
		if got := excluded(p); got != want {
			t.Errorf("excluded(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestClassifyAndVerdict(t *testing.T) {
	es := []entry{
		{"5", "5", "b.txt", ""}, {"5", "5", "a.txt", ""}, {"9", "1", "c.txt", ""}, {"-", "-", "x.bin", ""}, {"0", "0", "new.txt", "old.txt"},
		{"3", "4", "research-sdd/toolbelt/tests/fixtures/d.json", ""}, {"-", "-", "research-sdd/toolbelt/tests/fixtures/e.bin", ""}, {"0", "0", "empty.txt", ""},
	}
	tl := classify(es)
	var paths []string
	for _, f := range tl.files {
		paths = append(paths, f.path)
	}
	if got := strings.Join(paths, ","); got != "a.txt,b.txt,c.txt,empty.txt" {
		t.Errorf("order (lines desc, then path): %s", got)
	}
	if tl.authored != 30 || tl.adds != 19 || tl.dels != 11 || tl.exLines != 7 || tl.exFiles != 2 || len(tl.unmeasured) != 1 || len(tl.renames) != 1 || tl.renames[0] != "old.txt -> new.txt" {
		t.Errorf("%+v", tl)
	}
	for _, c := range []struct {
		t    tally
		want string
	}{
		{tally{}, stEmpty},
		{tally{nentries: 1, exFiles: 1}, stExcluded},
		{tally{nentries: 2, exFiles: 1, renames: []string{"a -> b"}}, stUnmeas},
		{tally{nentries: 1, unmeasured: []string{"x"}}, stUnmeas},
		{tally{nentries: 1, files: []fileRow{{}}, authored: 10}, stOK},
		{tally{nentries: 1, files: []fileRow{{}}, authored: 11}, stOver},
		{tally{nentries: 1, files: []fileRow{{}}, authored: 20}, stOver},
		{tally{nentries: 1, files: []fileRow{{}}, authored: 21}, stRefuse},
	} {
		if got := c.t.verdict(10, 20); got != c.want {
			t.Errorf("%+v: %s, want %s", c.t, got, c.want)
		}
	}
}

func TestUnitKey(t *testing.T) {
	for p, want := range map[string]string{
		toolbelt + "tests/kit-foo.test.sh": toolbelt + "kit-foo",
		toolbelt + "maint/kit-foo.sh":      toolbelt + "kit-foo",
		toolbelt + "lib/x.y.sh":            toolbelt + "x.y",
		toolbelt + "tests/data.txt":        toolbelt + "tests/data",
		toolbelt + "tests/a/b.c.d":         toolbelt + "tests/a/b.c",
		"pkg/tests/x.test.sh":              "pkg/x",
		"a/tests/b/tests/c.test.sh":        "a/tests/b/c",
		"docs/readme.md":                   "docs/readme",
		"top.go":                           "./top",
		"d/noext":                          "d/noext",
		"pkg/tests/x.go":                   "pkg/tests/x",
	} {
		if got := unitKey(p); got != want {
			t.Errorf("unitKey(%q) = %q, want %q", p, got, want)
		}
	}
}

func TestSplitPacking(t *testing.T) {
	f := func(p string, n int) fileRow { return fileRow{lines: n, path: p} }
	got := split([]fileRow{f("a/x.go", 300), f("b/y.go", 200), f("c/z.go", 100), f("d/w.go", 0)}, 400)
	var s []string
	for _, c := range got {
		var ps []string
		for _, r := range c.files {
			ps = append(ps, r.path)
		}
		s = append(s, strings.Join(ps, "+")+":"+strconv.Itoa(c.lines)+":"+c.note)
	}
	// units in key order: a/x (300) | b/y (200) does not fit, new chunk | c/z (100) fits | d/w (0) fits
	if want := "a/x.go:300:,b/y.go+c/z.go+d/w.go:300:"; strings.Join(s, ",") != want {
		t.Errorf("%s", strings.Join(s, ","))
	}
	got = split([]fileRow{f("a/big.go", 500), f("b/small.go", 5)}, 400)
	if len(got) != 2 || got[0].note != "single-unit-over-budget" || got[0].lines != 500 || got[1].idx != 2 || got[1].lines != 5 || got[1].note != "" {
		t.Errorf("%+v", got)
	}
	got = split([]fileRow{f("a/small.go", 5), f("b/big.go", 500)}, 400)
	if len(got) != 2 || got[0].idx != 1 || got[0].lines != 5 || got[1].idx != 2 || got[1].note != "single-unit-over-budget" {
		t.Errorf("a big unit never shares a chunk: %+v", got)
	}
	if got = split(nil, 400); len(got) != 0 {
		t.Errorf("%+v", got)
	}
}

func TestRepeatedAndHotspots(t *testing.T) {
	diff := "diff --git a/f b/f\n+++ b/f\n+++ not-counted-before-a-hunk\n@@ -0,0 +1,4 @@\n+  a \"x\" 1\n+a 'y' 22\n+\n+b\n\\ No newline at end of file\ndiff --git a/g b/g\n+skipped\n@@ -1 +1 @@\n-gone\n+a \"z\" 3\n"
	total, best, pat := repeated(diff)
	if total != 4 || best != 3 || pat != "a S N" {
		t.Errorf("total %d best %d pattern %q", total, best, pat)
	}
	if _, _, pat = repeated("@@\n+b\n+a\n"); pat != "a" {
		t.Errorf("tie goes to the smallest pattern: %q", pat)
	}
	if total, best, pat = repeated(""); total != 0 || best != 0 || pat != "" {
		t.Errorf("empty diff: %d %d %q", total, best, pat)
	}
	tl := tally{authored: 100, files: []fileRow{{lines: 41, path: "big.sh"}, {lines: 40, path: "edge.sh"}, {lines: 19, path: "r.sh", old: "o.sh"}}}
	var calls [][]string
	body := "@@\n" + strings.Repeat("+x 1\n", 9) + "+y\n"
	hs, un := hotspots(tl, "b...h", func(a ...string) (string, bool) {
		calls = append(calls, a)
		return body, true
	})
	if len(calls) != 1 || calls[0][0] != "--literal-pathspecs" || calls[0][len(calls[0])-1] != "big.sh" {
		t.Errorf("only files above 40%% are read: %v", calls)
	}
	if len(hs) != 1 || hs[0] != (hotspot{"big.sh", 41, 41, 90, "x N"}) || len(un) != 0 {
		t.Errorf("%+v %v", hs, un)
	}
	// 8 of 10 repeat: exactly 80% counts; 7 of 10 does not; 9 non-blank lines are too few
	for rep, want := range map[int]bool{8: true, 7: false} {
		b := "@@\n" + strings.Repeat("+x 1\n", rep) + strings.Repeat("+u\n", 0)
		for i := rep; i < 10; i++ {
			b += "+distinct" + strings.Repeat("a", i) + "\n"
		}
		if hs, _ := hotspots(tally{authored: 10, files: []fileRow{{lines: 10, path: "p"}}}, "r", func(...string) (string, bool) { return b, true }); (len(hs) == 1) != want {
			t.Errorf("%d of 10: %+v", rep, hs)
		}
	}
	few := "@@\n" + strings.Repeat("+x 1\n", 9)
	if hs, _ := hotspots(tally{authored: 9, files: []fileRow{{lines: 9, path: "p"}}}, "r", func(...string) (string, bool) { return few, true }); len(hs) != 0 {
		t.Errorf("9 lines are too few: %+v", hs)
	}
	// a rename passes both paths to git; a failing diff is reported as unchecked, never as no churn
	var spec []string
	hs, un = hotspots(tally{authored: 10, files: []fileRow{{lines: 10, path: "n.sh", old: "o.sh"}}}, "r", func(a ...string) (string, bool) {
		spec = a
		return "", false
	})
	if len(hs) != 0 || !reflect.DeepEqual(un, []string{"n.sh"}) || !reflect.DeepEqual(spec[len(spec)-3:], []string{"--", "n.sh", "o.sh"}) {
		t.Errorf("%v %v %v", hs, un, spec)
	}
}

func TestJesc(t *testing.T) {
	if got := jesc("a\\b\"c\td\ne\rf\x01g\x7fhé"); got != "a\\\\b\\\"c\\td\\ne\\rf?g?hé" {
		t.Errorf("%q", got)
	}
}
