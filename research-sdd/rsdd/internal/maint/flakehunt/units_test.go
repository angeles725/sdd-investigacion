package flakehunt

import (
	"reflect"
	"testing"
)

func TestParseListDropsCommentsBlanksAndWhitespace(t *testing.T) {
	got := parseList("# head\n\n  a/b.test.sh  # tail\r\nc.test.sh\n\t\nlast")
	want := []string{"a/b.test.sh", "c.test.sh", "last"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestListedKeepsLinesVerbatimExceptBlanks(t *testing.T) {
	got := listed("a\n\n b \nc")
	if want := []string{"a", " b ", "c"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPassProblemTable(t *testing.T) {
	cases := map[string]string{
		"== 3 passed · 0 failed ==\n":                          "",
		"== 3 passed · 1 failed ==\n":                          "exit 0 but the summary reports 1 failed",
		"== 0 passed · 0 failed ==\n":                          "exit 0 but the summary reports zero test cases",
		"== 3 passed · 1 failed ==\n== 3 passed · 0 failed ==": "",
		"== 3 passed · 0 failed ==\n== 3 passed · 2 failed ==": "exit 0 but the summary reports 2 failed",
		"3 tests passed, 1 failed":                             "exit 0 but malformed summary line (want '== N passed · M failed ==') in L",
		"nothing":                                              "exit 0 but no '== N passed · M failed ==' summary line in L",
		"== 3 passed · 0 failed == trailing":                   "exit 0 but malformed summary line (want '== N passed · M failed ==') in L",
	}
	for log, want := range cases {
		if got := passProblem(log, "L"); got != want {
			t.Errorf("passProblem(%q) = %q, want %q", log, got, want)
		}
	}
}

func TestVerdictTable(t *testing.T) {
	pass := "== 1 passed · 0 failed ==\n"
	cases := []struct {
		name         string
		rc           int
		log          string
		status, want string
	}{
		{"pass", 0, pass, stPass, ""},
		{"skip", 0, "SKIP: why\n", stSkip, ""},
		{"skip not at line start", 0, " SKIP: why\n", stFail, "exit 0 but no '== N passed · M failed ==' summary line in L"},
		{"skip wins over a missing summary", 0, "x\nSKIP: y\n", stSkip, ""},
		{"timeout", 124, "  FAIL  slow\n", stTimeout, "FAIL  slow"},
		{"exit 1 with a FAIL line", 1, "a\n  FAIL  \tx\tb\n", stFail, "FAIL  \tx\tb"},
		{"exit 1 without one", 1, "boom\n", stFail, "exit=1, no '  FAIL  ' line in L"},
		{"signalled", 137, "", stFail, "exit=137, no '  FAIL  ' line in L"},
		{"exit 0, failed summary", 0, "== 2 passed · 1 failed ==\n  FAIL  later\n", stFail, "exit 0 but the summary reports 1 failed"},
	}
	for _, c := range cases {
		status, first := verdict(c.rc, c.log, "L")
		if status != c.status || first != flat(c.want) {
			t.Errorf("%s: got %s %q, want %s %q", c.name, status, first, c.status, flat(c.want))
		}
	}
}

// flat is the tab flattening results.tsv needs.
func flat(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] == '\t' {
			b[i] = ' '
		}
	}
	return string(b)
}

func TestValidateOrderAndMessages(t *testing.T) {
	nproc := func() (int, bool) { return 8, true }
	base := options{runs: "3", suiteTimeout: "900", tier: "all"}
	with := func(f func(*options)) options { o := base; f(&o); return o }
	cases := []struct {
		name string
		o    options
		msg  string
	}{
		{"runs and load faults report runs first", with(func(o *options) { o.runs = "0"; o.load = "x" }), "kit-flake-hunt: --runs must be an integer >= 1 (got '0')\n"},
		{"load", with(func(o *options) { o.load = "-1" }), "kit-flake-hunt: --load must be an integer >= 0 (got '-1')\n"},
		{"load timeout", with(func(o *options) { o.loadTimeout = "0" }), "kit-flake-hunt: --load-timeout must be an integer >= 1\n"},
		{"suite timeout", with(func(o *options) { o.suiteTimeout = "" }), "kit-flake-hunt: --suite-timeout must be an integer >= 1\n"},
		{"tier", with(func(o *options) { o.tier = "mid" }), "kit-flake-hunt: --tier must be core or all (got 'mid')\n"},
		{"evidence scheme", with(func(o *options) { o.evidence = "ftp://x" }), "kit-flake-hunt: --evidence-url must be an http(s) URL (got 'ftp://x')\n"},
		{"evidence space", with(func(o *options) { o.evidence = "http://x y" }), "kit-flake-hunt: --evidence-url must be one http(s) URL without whitespace\n"},
		{"lists", with(func(o *options) { o.suitesFile = "f"; o.suiteArgs = []string{"a"} }), "kit-flake-hunt: --suites and --suite are mutually exclusive\n"},
	}
	for _, c := range cases {
		if _, f := validate(c.o, nproc); f == nil || f.code != 2 || f.msg != c.msg {
			t.Errorf("%s: got %+v, want %q", c.name, f, c.msg)
		}
	}
	if c, f := validate(base, nproc); f != nil || c.load != 4 {
		t.Errorf("default load: %+v %+v, want 4", c, f)
	}
	if c, f := validate(with(func(o *options) { o.load = "0" }), nproc); f != nil || c.load != 0 {
		t.Errorf("--load 0 must stay 0: %+v %+v", c, f)
	}
	if _, f := validate(base, func() (int, bool) { return 0, false }); f == nil || f.msg != "degraded: kit-flake-hunt: nproc gave no usable CPU count; pass --load N explicitly\n" {
		t.Errorf("no nproc count: %+v", f)
	}
}

func TestFilenameSafe(t *testing.T) {
	for s, want := range map[string]bool{"a.test.sh": true, "A_b-1.mjs": true, "we ird": false, "it's": false, "é": false, "": true} {
		if got := filenameSafe(s); got != want {
			t.Errorf("filenameSafe(%q) = %v", s, got)
		}
	}
}
