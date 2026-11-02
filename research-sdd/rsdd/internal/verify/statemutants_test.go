//go:build unix

package verify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Oracle-free unit tests of the pure helpers of `rsdd verify state`. The expected values are the ones the frozen
// bash script / GNU tools produce (pinned by the differential tests under !nodiff); here they are literals, so the
// mutation run (nodiff) kills the boundary and negation mutants of the helpers.

func TestASCIICaseHelpersBoundaries(t *testing.T) {
	for _, c := range []struct{ in, lower, upper string }{
		{"@AZ[`az{", "@az[`az{", "@AZ[`AZ{"},
		{"A", "a", "A"},
		{"Z", "z", "Z"},
		{"a", "a", "A"},
		{"z", "z", "Z"},
		{"xAZy", "xazy", "XAZY"},
		{"", "", ""},
	} {
		if got := asciiLower(c.in); got != c.lower {
			t.Errorf("asciiLower(%q) = %q, want %q", c.in, got, c.lower)
		}
		if got := asciiUpper(c.in); got != c.upper {
			t.Errorf("asciiUpper(%q) = %q, want %q", c.in, got, c.upper)
		}
	}
}

func TestFirstWordAndDecimal(t *testing.T) {
	for in, want := range map[string]string{" x": "", "a b": "a", "ab": "ab", "": ""} {
		if got := firstWord(in); got != want {
			t.Errorf("firstWord(%q) = %q, want %q", in, got, want)
		}
	}
	for _, c := range []struct {
		in string
		v  int64
		ok bool
	}{
		{"0", 0, true}, {"09", 9, true}, {"9223372036854775807", 1<<63 - 1, true}, {"9223372036854775808", 0, false},
		{"9223372036854775800", 9223372036854775800, true}, {"92233720368547758070", 0, false},
		{"", 0, false}, {"1a", 0, false}, {"/", 0, false}, {":", 0, false}, {"-1", 0, false},
	} {
		if v, ok := decimal(c.in); v != c.v || ok != c.ok {
			t.Errorf("decimal(%q) = %d,%v want %d,%v", c.in, v, ok, c.v, c.ok)
		}
	}
}

func TestEnvFieldToleratesBlankEnvelopeLines(t *testing.T) {
	lines := []string{"<!-- research-state.v1 -->", "", "   ", "gaps_closed:", "covered_blocks: 3", "<!-- /research-state.v1 -->"}
	if got := envField(lines, "covered_blocks"); got != "3" {
		t.Errorf("envField = %q, want 3", got)
	}
	if got := envField(lines, "gaps_closed"); got != "" {
		t.Errorf("envField(valueless key) = %q, want empty", got)
	}
	if got := envField(lines, "absent"); got != "" {
		t.Errorf("envField(absent) = %q, want empty", got)
	}
}

func TestByteClassBoundaries(t *testing.T) {
	word, lowerAlnum := "AZaz09_-", "az09"
	for c := 0; c < 256; c++ {
		b := byte(c)
		if got, want := isWordByte(b), strings.IndexByte(word, b) >= 0 || (b > 'A' && b < 'Z') || (b > 'a' && b < 'z') || (b > '0' && b < '9'); got != want {
			t.Errorf("isWordByte(%q) = %v, want %v", b, got, want)
		}
		if got, want := isLowerAlnum(b), strings.IndexByte(lowerAlnum, b) >= 0 || (b > 'a' && b < 'z') || (b > '0' && b < '9'); got != want {
			t.Errorf("isLowerAlnum(%q) = %v, want %v", b, got, want)
		}
	}
}

func TestHasWordNegationWindow(t *testing.T) {
	for _, c := range []struct {
		s, w string
		want bool
	}{
		{"CLOSED", "CLOSED", true},
		{"x CLOSED", "CLOSED", true},
		{"CLOSED-x", "CLOSED", false},
		{"xCLOSED", "CLOSED", false},
		{"NOT CLOSED", "CLOSED", false},
		{"NO A B CLOSED", "CLOSED", true},
		{"NO A CLOSED", "CLOSED", false},
		{"never yet CLOSED", "CLOSED", false},
		{"a NOT, CLOSED", "CLOSED", false},
		{"A not B CLOSED", "CLOSED", true},
		{"NOT x y CLOSED CLOSED", "CLOSED", true},
		{"x CLOSEDy CLOSED", "CLOSED", true},
	} {
		if got := hasWord(c.s, c.w); got != c.want {
			t.Errorf("hasWord(%q, %q) = %v, want %v", c.s, c.w, got, c.want)
		}
	}
	for in, want := range map[string]string{"!!!": "", "ab!!": "ab", "": "", "a-b": "a-b", "!a": "!a"} {
		if got := trailingNonWord(in); got != want {
			t.Errorf("trailingNonWord(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMissingUnblockEntries(t *testing.T) {
	for _, c := range []struct {
		name, body string
		miss, ord  int
	}{
		{"needs without unblock", "- needs: a", 1, 0},
		{"needs at column zero", "needs: a", 1, 0},
		{"unblock then needs on separate lines", "unblock: b\nneeds: a", 0, 1},
		{"needs then unblock", "needs: a\nunblock: b", 0, 0},
		{"unblock before needs on one line", "- unblock: x needs: y", 0, 1},
		{"needs before unblock on one line", "- needs: x unblock: y", 0, 0},
		{"blank line then same-indent continuation closes the entry", "- needs: a\n\nunblock: b", 1, 0},
		{"blank line then deeper continuation stays in the entry", "- needs: a\n\n  unblock: b", 0, 0},
		{"two bullets", "- needs: a\n- needs: b unblock: c", 1, 0},
		// awk's NR*100000+column positions alias across lines: column 99999 of line 1 sits one before column 0 of line 2.
		{"unblock one position before needs", strings.Repeat(" ", 99999) + "unblock:\nneeds:", 0, 1},
		// awk's NR*100000+column aliases a column of 100000 with the next line; equal positions are not "before".
		{"equal awk positions", strings.Repeat(" ", 100000) + "unblock:\nneeds:", 0, 0},
	} {
		if miss, ord := missingUnblock(c.body); miss != c.miss || ord != c.ord {
			t.Errorf("%s: missingUnblock = %d,%d want %d,%d", c.name, miss, ord, c.miss, c.ord)
		}
	}
}

func TestNumLessAndArithSum(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"5", "5", false}, {"05", "5", false}, {"4", "5", true}, {"5", "4", false}, {"9", "10", true}, {"10", "9", false}, {"0", "0", false}, {"", "1", true}} {
		if got := numLess(c.a, c.b); got != c.want {
			t.Errorf("numLess(%q,%q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
	for _, c := range []struct {
		vals []string
		want int64
	}{{[]string{"0"}, 0}, {[]string{"7"}, 7}, {[]string{"010"}, 8}, {[]string{"0", "5", "07"}, 12}, {[]string{"10", "010"}, 18}} {
		if got := arithSum(c.vals...); got != c.want {
			t.Errorf("arithSum(%q) = %d, want %d", c.vals, got, c.want)
		}
	}
}

func TestDecNumberStringMatchesJQ(t *testing.T) {
	// jq 1.8 `jq -c .` of each literal.
	for in, want := range map[string]string{
		"1": "1", "1.0": "1.0", "1e2": "1E+2", "1e-2": "0.01", "0.5": "0.5", "0.05": "0.05", "0.000001": "0.000001",
		"0.0000001": "1E-7", "1.5": "1.5", "12.5": "12.5", "-1.5": "-1.5", "100": "100", "1E+2": "1E+2", "1e-7": "1E-7",
		"1.5e-7": "1.5E-7", "15e-8": "1.5E-7", "2.5e10": "2.5E+10", "0.1e1": "1", "0": "0", "0.0": "0.0", "1.50": "1.50",
		"1e0": "1", "123e5": "1.23E+7", "-0.5": "-0.5", "1e-6": "0.000001", "1e-5": "0.00001", "10e-7": "0.0000010",
	} {
		if got := decNumberString(in); got != want {
			t.Errorf("decNumberString(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDirnameBasename(t *testing.T) {
	for in, want := range map[string]string{"/x": "/", "x": ".", "/a/b": "/a", "/": "/", "": ".", "a/b/": "a", "//x": "/", "a//b": "a"} {
		if got := dirname(in); got != want {
			t.Errorf("dirname(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIsStateName(t *testing.T) {
	for in, want := range map[string]bool{
		"RESEARCH-STATE.md": true, "RESEARCH-STATE-auth.md": true, "RESEARCH-STATE": false, "RESEARCH-STATE.template.md": false,
		"RESEARCH-STATE-x.template.md": false, "RESEARCH-STAT.md": false, "xRESEARCH-STATE.md": false, "RESEARCH-STATE.txt": false, "": false,
	} {
		if got := isStateName(in); got != want {
			t.Errorf("isStateName(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestRealpathLiteralOutcomes(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sdWrite(t, filepath.Join(root, "f"), "x")
	sdWrite(t, filepath.Join(root, "d", "g"), "x")
	chain := func(n int) string { // c1 -> f, c2 -> c1, ... cN -> c(N-1)
		for i := 1; i <= n; i++ {
			target := "f"
			if i > 1 {
				target = fmt.Sprintf("c%d", i-1)
			}
			if err := os.Symlink(target, filepath.Join(root, fmt.Sprintf("c%d", i))); err != nil && !os.IsExist(err) {
				t.Fatal(err)
			}
		}
		return filepath.Join(root, fmt.Sprintf("c%d", n))
	}
	v := fsView{cwd: root}
	for _, c := range []struct {
		in, want string
		ok       bool
	}{
		{"/..", "/", true},
		{"/../..", "/", true},
		{"/../" + strings.TrimPrefix(root, "/"), root, true},
		{root + "/f", root + "/f", true},
		{root + "/f/", "", false},
		{root + "/f/..", "", false},
		{root + "/f/.", "", false},
		{root + "/f/x", "", false},
		{root + "/d/../f", root + "/f", true},
		{root + "/missing", root + "/missing", true},
		{root + "/missing/x", "", false},
		{root + "/d/", root + "/d", true},
		{chain(40), root + "/f", true},
		{chain(41), "", false},
	} {
		got, ok := v.realpath(c.in)
		if ok != c.ok || got != c.want {
			t.Errorf("realpath(%q) = %q,%v want %q,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestRunMergedEnvironment(t *testing.T) {
	d := t.TempDir()
	script := filepath.Join(d, "s.sh")
	sdWrite(t, script, "echo \"foo=${RSDDFOO:-unset}\"\n")
	with := cli.Stdio{Cwd: d, Environ: func() []string { return []string{"RSDDFOO=bar", "PATH=" + os.Getenv("PATH")} }}
	if out, rc := runMerged(with, script, d, "state"); out != "foo=bar" || rc != 0 {
		t.Errorf("with an environment: %q rc=%d, want foo=bar rc=0", out, rc)
	}
	t.Setenv("RSDDFOO", "leaked")
	without := cli.Stdio{Cwd: d}
	if out, rc := runMerged(without, "/usr/bin/env", d, "state"); rc == 0 && strings.Contains(out, "RSDDFOO") {
		t.Errorf("a nil Environ must run with an empty environment, got %q", out)
	}
}

func TestBasenameAndRegularMarkdown(t *testing.T) {
	for in, want := range map[string]string{"": "", "/": "/", "//": "/", "a": "a", "a/b": "b", "a/b/": "b", "/a": "a"} {
		if got := basename(in); got != want {
			t.Errorf("basename(%q) = %q, want %q", in, got, want)
		}
	}
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "a.md"), "x")
	sdWrite(t, filepath.Join(d, "b.txt"), "x")
	if err := os.Symlink("a.md", filepath.Join(d, "link.md")); err != nil {
		t.Fatal(err)
	}
	v := fsView{cwd: d}
	for _, dir := range []string{d, d + "/"} {
		got := v.regularMarkdown(dir)
		if want := []string{strings.TrimSuffix(dir, "/") + "/a.md"}; len(got) != 1 || got[0] != want[0] {
			t.Errorf("regularMarkdown(%q) = %q, want %q", dir, got, want)
		}
	}
	if got := v.regularMarkdown(filepath.Join(d, "absent")); got != nil {
		t.Errorf("regularMarkdown(absent) = %q, want nil", got)
	}
}

func TestJqQuoteMatchesJQ(t *testing.T) {
	var b strings.Builder
	jqQuote(&b, "a\"b\\c\nd\re\tf\bg\fh\x01\x1f\x7f \u00e9<&>")
	if want := `"a\"b\\c\nd\re\tf\bg\fh\u0001\u001f\u007f é<&>"`; b.String() != want {
		t.Errorf("jqQuote = %s, want %s", b.String(), want)
	}
}

// TestFindStatesByteOrder pins the walk order: byte order within each directory, a directory's subtree before the
// next entry, whatever order the filesystem returns (#2477). Names are created in reverse so creation order and
// byte order disagree.
func TestFindStatesByteOrder(t *testing.T) {
	d := t.TempDir()
	rel := []string{
		"RESEARCH-STATE-a.md", "RESEARCH-STATE-b.md", "RESEARCH-STATE-c.md", "RESEARCH-STATE-d.md",
		"RESEARCH-STATE-e.md", "RESEARCH-STATE.md", "sub/RESEARCH-STATE-ui.md", "sub/deeper/RESEARCH-STATE.md",
		"zz/RESEARCH-STATE-z.md",
	}
	for i := len(rel) - 1; i >= 0; i-- {
		sdWrite(t, filepath.Join(d, rel[i]), "x")
	}
	got := fsView{cwd: d}.findStates(d)
	want := make([]string, len(rel))
	for i, r := range rel {
		want[i] = d + "/" + r
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("findStates order:\n got %q\nwant %q", got, want)
	}
}
