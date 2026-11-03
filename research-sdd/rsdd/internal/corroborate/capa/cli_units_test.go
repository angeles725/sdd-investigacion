package capa

// Unit tests of the command line and the rules checks. They replace the Python unit case T15-16 of the
// retired tests/capa.test.sh; the differential tests against the legacy tool are in parity_linux_test.go.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------------------------------------------------------- argument parsing

func TestParseArgsValid(t *testing.T) {
	o, err := parseArgs([]string{"--input", "a//b", "--output=out/", "--manifest-cli", "m", "--timeout", "1_0", "--max-cap", "+7", "--rules", "r"})
	if err != nil {
		t.Fatal(err)
	}
	if o.input != "a/b" || o.output != "out" || o.manifestCLI != "m" || o.rules != "r" || o.timeout.Int64() != 10 || o.maxCapabilities.Int64() != 7 {
		t.Fatalf("%+v", o)
	}
	d, err := parseArgs([]string{"--input", "i", "--output", "o", "--manifest-cli", "m"})
	if err != nil || d.rules != "~/.local/share/capa-rules" || d.timeout.Int64() != 300 || d.maxCapabilities.Int64() != 500 {
		t.Fatalf("defaults: %+v %v", d, err)
	}
}

func TestParseArgsErrors(t *testing.T) {
	ok := []string{"--input", "a", "--output", "b", "--manifest-cli", "c"}
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"ambiguous", []string{"--m", "x"}, "ambiguous option: --m could match --max-capabilities, --manifest-cli"},
		{"missing all", nil, "the following arguments are required: --input, --output"},
		{"missing value", []string{"--timeout"}, "argument --timeout: expected one argument"},
		{"option as value", []string{"--input", "-a"}, "argument --input: expected one argument"},
		{"dash dash as value", []string{"--timeout", "--", "5"}, "argument --timeout: expected one argument"},
		{"bad int", append([]string{"--timeout", "x"}, ok...), "argument --timeout: invalid int value: 'x'"},
		{"float is not int", append([]string{"--timeout=1e3"}, ok...), "argument --timeout: invalid int value: '1e3'"},
		{"extra", append(append([]string{}, ok...), "extra"), "unrecognized arguments: extra"},
		{"extra after dashes", append(append([]string{}, ok...), "--", "x"), "unrecognized arguments: -- x"},
		{"unknown option reported after required", append(append([]string{}, ok...), "--unk=1", "x"), "unrecognized arguments: --unk=1 x"},
		{"required wins over unknown", []string{"--foo"}, "the following arguments are required: --input, --output"},
		{"help with value", []string{"--help=3"}, "argument -h/--help: ignored explicit argument '3'"},
		{"short help with =", []string{"-h=3"}, "argument -h/--help: ignored explicit argument '3'"},
	}
	for _, c := range cases {
		_, err := parseArgs(c.args)
		var ae *argError
		if !errors.As(err, &ae) || ae.msg != c.want {
			t.Errorf("%s: got %v, want %q", c.name, err, c.want)
		}
	}
}

func TestParseArgsHelpAndNegativeNumbers(t *testing.T) {
	for _, a := range [][]string{{"-h"}, {"--help"}, {"--h"}, {"-hx"}, {"-h", "--bogus"}} {
		if _, err := parseArgs(a); !errors.Is(err, errHelp) {
			t.Errorf("%v: %v", a, err)
		}
	}
	o, err := parseArgs([]string{"--timeout", "-5", "--input", "a", "--output", "b", "--manifest-cli", "c"})
	if err != nil || o.timeout.Int64() != -5 {
		t.Fatalf("a negative number is a value: %+v %v", o, err)
	}
}

func TestParsePyInt(t *testing.T) {
	good := map[string]int64{"٣": 3, "١٢": 12, "0": 0, " 12 ": 12, "-3": -3, "+4": 4, "1_000": 1000, "00": 0}
	for s, want := range good {
		if n, ok := parsePyInt(s); !ok || n.Int64() != want {
			t.Errorf("%q: %v %v", s, n, ok)
		}
	}
	for _, s := range []string{"", "_1", "1_", "1__0", "1.0", "0x10", "1e3", "--1", strings.Repeat("9", 4301)} {
		if _, ok := parsePyInt(s); ok {
			t.Errorf("%q must be rejected", s)
		}
	}
	if n, ok := parsePyInt(strings.Repeat("9", 4300)); !ok || n.Sign() != 1 {
		t.Error("4300 digits is the largest accepted size")
	}
}

// ---------------------------------------------------------------- usage and help

func TestUsageWrapsLikeArgparse(t *testing.T) {
	want := "usage: corroborate-capa [-h] --input INPUT --output OUTPUT [--rules RULES]\n" +
		"                        [--timeout TIMEOUT]\n" +
		"                        [--max-capabilities MAX_CAPABILITIES]\n"
	if got := usageText(terminalWidth("")); got != want {
		t.Fatalf("usage at 80 columns:\n%s", got)
	}
	one := usageText(terminalWidth("200"))
	if strings.Count(one, "\n") != 1 || !strings.HasPrefix(one, "usage: corroborate-capa [-h] --input INPUT --output OUTPUT [--rules RULES] [--timeout TIMEOUT]") {
		t.Fatalf("usage at 200 columns must be one line:\n%s", one)
	}
	if terminalWidth("0") != 78 || terminalWidth("junk") != 78 || terminalWidth("-4") != 78 || terminalWidth("100") != 98 {
		t.Error("$COLUMNS is used only when it is a positive integer")
	}
}

func TestHelpTextAt80Columns(t *testing.T) {
	want := `usage: corroborate-capa [-h] --input INPUT --output OUTPUT [--rules RULES]
                        [--timeout TIMEOUT]
                        [--max-capabilities MAX_CAPABILITIES]

options:
  -h, --help            show this help message and exit
  --input INPUT         PE/ELF/.NET binary to analyse
  --output OUTPUT       New output directory (must not exist)
  --rules RULES         capa rules directory (default: ~/.local/share/capa-
                        rules)
  --timeout TIMEOUT     Wall-clock timeout for capa (seconds, default 300)
  --max-capabilities MAX_CAPABILITIES
                        Maximum capabilities sampled in the inventory (default
                        500)
`
	if got := helpText(78); got != want {
		t.Fatalf("help:\n%s", got)
	}
}

// ---------------------------------------------------------------- rules (T15)

// T15a: /home and /home/<user> are rejected by the scope guard; deeper paths pass the shape check.
func TestRulesScopeGuard(t *testing.T) {
	e := rulesEnv{cwd: "/", home: func() (string, bool) { return "/nonexistent/h/ome", true }}
	for _, broad := range []string{"/", "/home", "/home/someuser", "/usr", "/tmp", "/etc"} {
		err := rulesScopeGuard(e, broad)
		var f *fail
		if !errors.As(err, &f) || !strings.HasPrefix(f.msg, "--rules path rejected by bind-scope guard: ") {
			t.Errorf("%s must be rejected: %v", broad, err)
		}
	}
	if err := rulesScopeGuard(e, "/home/someuser/rules"); err != nil {
		t.Errorf("/home/<user>/<subdir> is acceptable: %v", err)
	}
}

func TestRulesPathDigestIsStructural(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "x", "y"), 0o755)
	os.WriteFile(filepath.Join(dir, "x", "y", "r.yml"), []byte("1"), 0o644)
	os.WriteFile(filepath.Join(dir, "a.yml"), []byte("1"), 0o644)
	os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("1"), 0o644)
	d1, err := rulesPathDigest(dir)
	if err != nil || !strings.HasPrefix(d1, "sha256:") {
		t.Fatal(d1, err)
	}
	os.WriteFile(filepath.Join(dir, "a.yml"), []byte("changed content"), 0o644)
	if d2, _ := rulesPathDigest(dir); d2 != d1 {
		t.Error("content changes must not change the path digest")
	}
	os.WriteFile(filepath.Join(dir, "b.yml"), nil, 0o644)
	if d3, _ := rulesPathDigest(dir); d3 == d1 {
		t.Error("a new rule file must change the digest")
	}
}

func TestBindRulesInsertsBeforeSeparator(t *testing.T) {
	got, err := bindRules([]string{"bwrap", "--x", "--"}, "/r/rules")
	want := []string{"bwrap", "--x", "--dir", "/tmp/rsdd/capa-rules", "--ro-bind", "/r/rules", "/tmp/rsdd/capa-rules", "--"}
	if err != nil || strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := bindRules([]string{"bwrap"}, "/r"); err == nil {
		t.Error("a prefix without the trailing -- is refused")
	}
}

// A strict resolve of a regular file succeeds, and fails with "Not a directory" when something follows the file (a
// further component). These are the only checks of that branch, kept now that --manifest-cli
// (the strict resolve of a file) is ignored.
func TestResolveStrictThroughRegularFile(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "plain")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := resolve(file, true, dir); err != nil || got != file {
		t.Errorf("resolve(file) = %q, %v; want %q, nil", got, err, file)
	}
	for _, p := range []string{file + "/next", file + "/next/deeper"} {
		if _, err := resolve(p, true, dir); err == nil || !strings.Contains(err.Error(), "Not a directory") {
			t.Errorf("resolve(%q) error = %v, want a Not a directory error", p, err)
		}
	}
	if got, err := resolve(dir+"/", true, dir); err != nil || got != dir {
		t.Errorf("resolve(dir/) = %q, %v; want %q, nil", got, err, dir)
	}
}

func TestPathHelpersMatchPathlib(t *testing.T) {
	cases := []struct{ in, norm, parent, name string }{
		{"a//b/", "a/b", "a", "b"}, {"", ".", ".", ""}, {"/", "/", "/", ""}, {"/a", "/a", "/", "a"}, {"./x/./y", "x/y", "x", "y"},
		{"//a", "//a", "//", "a"}, {"///a", "/a", "/", "a"}, {"../a", "../a", "..", "a"},
	}
	for _, c := range cases {
		n := pyNorm(c.in)
		if n != c.norm || pyParent(n) != c.parent || pyName(n) != c.name {
			t.Errorf("%q: norm %q parent %q name %q", c.in, n, pyParent(n), pyName(n))
		}
	}
}
