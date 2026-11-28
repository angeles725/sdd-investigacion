//go:build unix

package verify

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The pre-filters of kit issue #2645 may only drop lines their regexp could not match.
func TestMayContainFoldNeverDropsAMatch(t *testing.T) {
	t.Parallel()
	re := regexp.MustCompile(`(?i)gaps? closed|coverage metric`)
	for _, l := range []string{
		"", "plain", "Gaps CLOSED: 3", "gap closed", "COVERAGE METRIC: 1/2", "cloſed gaps cloſed", "gap cloSed",
		"gaps closeD", "Coverage Metric", "cobertura cerrada", "ñandú gaps closed", "gapsK closed", "gaps ĸlosed",
	} {
		if re.MatchString(l) && !mayContainFold(l, "closed", "coverage metric") {
			t.Errorf("mayContainFold dropped %q, which the regexp matches", l)
		}
	}
}

func TestCountBlocksPrefixFilterMatchesPlainFilter(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	for _, n := range []string{"a-block1.md", "a-bloque2-x.md", "b-block1.md", "ab-block3.md", "notes.md", "a-block.md", "xa-block9.md"} {
		if err := os.WriteFile(filepath.Join(dir, n), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, prefix := range []string{"", "a-", "b-", "z-", "a.", "(a|b)-"} {
		v := &verifier{fs: fsView{}}
		fast := v.countBlocks(dir, prefix)
		out, _ := kit.FilterBlockFiles(v.mdLines(dir), false, prefix)
		if want := fmt.Sprint(len(out)); fast != want {
			t.Errorf("prefix %q: filtered count %s, plain filter %s", prefix, fast, want)
		}
	}
}

// BenchmarkRunStateCorpus times `rsdd verify state` over a real corpus (kit issue #2645). It asserts nothing about
// time: the corpus is $RSDD_BENCH_STATE_DIR, else $HOME/niagara-research, and the benchmark skips when it is absent.
// Profile with: go test -run '^$' -bench RunStateCorpus -cpuprofile cpu.out ./internal/verify/
func BenchmarkRunStateCorpus(b *testing.B) {
	dir := os.Getenv("RSDD_BENCH_STATE_DIR")
	if dir == "" {
		dir = filepath.Join(os.Getenv("HOME"), "niagara-research")
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		b.Skipf("corpus %s is absent", dir)
	}
	toolbelt := kitroot.Path(b, "toolbelt")
	env := append(os.Environ(), "RSDD_TOOLBELT_DIR="+toolbelt)
	get := func(k string) string {
		for i := len(env) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(env[i], k+"="); ok {
				return v
			}
		}
		return ""
	}
	cwd, _ := os.Getwd()
	s := cli.Stdio{Out: io.Discard, Err: io.Discard, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: cwd}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		RunState([]string{dir}, s)
	}
}

// A run reads one INDEX.md once, however many state files share its directory: the corpus is read-only for the
// length of a run, so the answer is memoized per path (kit issue #2686). A fresh run reads it again.
func TestIndexHasPlaceholdersIsMemoizedPerRun(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	idx := filepath.Join(dir, "INDEX.md")
	write := func(s string) {
		t.Helper()
		if err := os.WriteFile(idx, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("| id | <SUBJECT> |\n")
	v := &verifier{fs: fsView{}}
	if !v.indexHasPlaceholders(idx) {
		t.Fatal("a template placeholder was not found")
	}
	write("no placeholder here\n")
	if !v.indexHasPlaceholders(idx) {
		t.Error("the second ask re-read INDEX.md instead of using the run's first answer")
	}
	if fresh := (&verifier{fs: fsView{}}); fresh.indexHasPlaceholders(idx) {
		t.Error("a new run kept the previous run's answer")
	}
	for _, c := range []struct{ name, text string }{
		{"lower-case angle word", "<subject>\n"},
		{"unterminated", "<SUBJECT\n"},
		{"empty angle pair", "<>\n"},
		{"placeholder after other text", "a <b> c <D_1-X>\n"},
	} {
		write(c.text)
		got := (&verifier{fs: fsView{}}).indexHasPlaceholders(idx)
		if want := c.name == "placeholder after other text"; got != want {
			t.Errorf("%s: got %v, want %v", c.name, got, want)
		}
	}
	if (&verifier{fs: fsView{}}).indexHasPlaceholders(filepath.Join(dir, "absent.md")) {
		t.Error("an unreadable INDEX.md must read as no placeholder")
	}
}

// mayContainFold runs on every line of every state file: it must not allocate (kit issue #2686).
func TestMayContainFoldDoesNotAllocate(t *testing.T) {
	// Not parallel: AllocsPerRun measures the whole process.
	lines := []string{"", "plain text", "## Coverage Metric: 3/4", "GAPS CLOSED", "a long line without any anchor " + strings.Repeat("x", 200)}
	if n := testing.AllocsPerRun(50, func() {
		for _, l := range lines {
			mayContainFold(l, "closed", "coverage metric", "coverage (after")
		}
	}); n != 0 {
		t.Errorf("mayContainFold allocated %v time(s) per run", n)
	}
}

// The alloc-free fold search must agree with the lower-casing reference on every input.
func TestMayContainFoldMatchesReference(t *testing.T) {
	t.Parallel()
	ref := func(l string, lits ...string) bool {
		if strings.Contains(l, "\u017f") || strings.Contains(l, "\u212a") {
			return true
		}
		low := asciiLower(l)
		for _, lit := range lits {
			if strings.Contains(low, lit) {
				return true
			}
		}
		return false
	}
	alphabet := []string{"c", "C", "l", "L", "o", "O", "s", "S", "e", "d", "D", " ", "(", "é", "\u017f", "\u212a", "K", "\xff", "x"}
	lits := [][]string{{"closed"}, {"closed", "coverage metric"}, {"s"}, {"co"}, {"("}, {""}, {"cl", "os"}}
	var gen func(prefix string, depth int)
	n := 0
	gen = func(prefix string, depth int) {
		for _, l := range lits {
			if got, want := mayContainFold(prefix, l...), ref(prefix, l...); got != want {
				t.Fatalf("mayContainFold(%q, %q) = %v, reference %v", prefix, l, got, want)
			}
		}
		n++
		if depth == 0 {
			return
		}
		for _, a := range alphabet {
			gen(prefix+a, depth-1)
		}
	}
	gen("", 3)
	for _, l := range []string{"Gaps CLOSED: 3", "COVERAGE METRIC: 1/2", "xxCoverage (After", "coverage (afte", "cLoSeD", "CLOSE", "closeD gaps", "xxxxxxxxxxxxxxxxxclose"} {
		for _, ls := range lits {
			if got, want := mayContainFold(l, ls...), ref(l, ls...); got != want {
				t.Errorf("mayContainFold(%q, %q) = %v, reference %v", l, ls, got, want)
			}
		}
	}
	if n < 1000 {
		t.Fatalf("generator produced only %d inputs", n)
	}
}

// foldAlt decides a line holding no non-ASCII fold character by its literals alone, and hands any other line to the
// regexp (kit issue #2686). The regexp here never matches, so the verdict shows which side decided.
func TestFoldAltDispatch(t *testing.T) {
	t.Parallel()
	f := foldAlt{re: regexp.MustCompile(`[^\x00-\x{10FFFF}]`), lits: []string{"gap closed", "gaps closed"}}
	for _, c := range []struct {
		line string
		want bool
	}{
		{"all GAPS Closed here", true},
		{"gap closed", true},
		{"gap  closed", false},
		{"", false},
		{"gaps closeD", true},
		{"ſ gaps closed", false}, // a fold character: the regexp decides
		{"gap cloſed", false},
		{"gap closed K", false},
	} {
		if got := f.MatchString(c.line); got != c.want {
			t.Errorf("MatchString(%q) = %v, want %v", c.line, got, c.want)
		}
	}
}

// The literal side must decide exactly as the regexp it stands for, on every line.
func TestFoldAltAgreesWithRegexp(t *testing.T) {
	t.Parallel()
	for _, f := range []foldAlt{reCoverageLine} {
		if len(f.lits) == 0 {
			t.Fatal("foldAlt without literals")
		}
		alphabet := []string{"c", "C", "o", "l", "s", "S", "e", "d", "g", "a", "p", " ", "(", "r", "m", "ſ", "K", "\xff", "é"}
		var gen func(prefix string, depth int)
		gen = func(prefix string, depth int) {
			if got, want := f.MatchString(prefix), f.re.MatchString(prefix); got != want {
				t.Fatalf("%q: literals say %v, regexp says %v", prefix, got, want)
			}
			if depth == 0 {
				return
			}
			for _, a := range alphabet {
				gen(prefix+a, depth-1)
			}
		}
		gen("", 3)
		for _, l := range []string{
			"coverage metric: 3/4", "Declared Gaps Closed: 2/9", "gap closed", "GAPS CLOSED", "gaps  closed", "gapsclosed",
			"Coverage (after B12): 4/9", "coverage (afte", "coverage ( after", "x coverage metric", "gaps cloſed", "declared gaps closed",
			"| B1-G1 | pending | closed later |", "the gap is closed", "Gap Closed.",
		} {
			if got, want := f.MatchString(l), f.re.MatchString(l); got != want {
				t.Errorf("%q: literals say %v, regexp says %v", l, got, want)
			}
		}
	}
}

// PRESERVE (kit issue #2686): the walk reads each directory's entry types instead of lstat-ing every entry; a
// symlinked directory is still not entered (a symlink to a state file is still listed, nothing is filtered by
// type), a directory named like a state file is listed and entered, and the walk stops at depth 3.
func TestFindStatesEntryKinds(t *testing.T) {
	t.Parallel()
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "real/RESEARCH-STATE-in-real.md"), "x")
	sdWrite(t, filepath.Join(d, "one/two/RESEARCH-STATE-depth3.md"), "x")
	sdWrite(t, filepath.Join(d, "one/two/three/RESEARCH-STATE-depth4.md"), "x")
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE-dir.md/RESEARCH-STATE-inner.md"), "x")
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE-file.md"), "x")
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE-tpl.template.md"), "x")
	sdWrite(t, filepath.Join(d, ".git/RESEARCH-STATE-git.md"), "x")
	for link, target := range map[string]string{"linkdir": "real", "RESEARCH-STATE-link.md": "RESEARCH-STATE-file.md", "RESEARCH-STATE-dangling.md": "absent"} {
		if err := os.Symlink(target, filepath.Join(d, link)); err != nil {
			t.Fatal(err)
		}
	}
	got := fsView{View: fsview.View{Cwd: d}}.findStates(d)
	var want []string
	for _, r := range []string{
		"RESEARCH-STATE-dangling.md", "RESEARCH-STATE-dir.md", "RESEARCH-STATE-dir.md/RESEARCH-STATE-inner.md",
		"RESEARCH-STATE-file.md", "RESEARCH-STATE-link.md", "one/two/RESEARCH-STATE-depth3.md", "real/RESEARCH-STATE-in-real.md",
	} {
		want = append(want, d+"/"+r)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("findStates:\n got %q\nwant %q", got, want)
	}
}
