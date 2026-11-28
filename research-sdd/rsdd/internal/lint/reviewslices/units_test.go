package reviewslices

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Guard -> test. The shell suite (tests/plan-review-slices.test.sh) used to prove each guard by mutating the text of
// the bash script; the script is a shim now, so each mutant moved here. Every guard below was mutated by hand (one
// mutant per guard) and the named test turned red under `go test -tags nodiff`; the four guards that need a real git
// name a scenario of the golden replay (golden_test.go) in brackets instead. `make teeth TEETH_PKG=./internal/lint/reviewslices`
// mutation-checks the whole package.
//
//	shell mutant        guard                                                     test
//	fits-at-equal       a slice may hold exactly max lines (<=)                   TestPlannerBoundary
//	unsplittable-gate   a commit over max is cut out (>)                          TestPlannerUnsplittable
//	unsplit-flag        the UNSPLITTABLE tag is printed on that slice only        TestPlannerUnsplittable
//	deletions-counted   lines = additions + deletions                             TestParseNumstat
//	binary-detected     `-` `-` rows are binary files, not lines                  TestParseNumstat
//	binary-typed        binary=<n> appears on the slice and on the plan, only     TestPlannerBinaryField
//	                    when present
//	flush-final         the last open slice is printed                            TestPlannerFinishFlushes
//	base-is-parent      base= is the abbreviated first parent                     TestMeasure
//	root-typed          a root commit reads base=ROOT                             TestMeasure
//	parents-checked     a failed parent lookup is exit 2, not a root commit       TestMeasureFailuresAreTyped
//	emptytree-checked   a failed empty-tree computation is exit 2                 TestMeasureFailuresAreTyped
//	malformed-check     a numstat row that is neither counts nor `-` is exit 2    TestParseNumstat, TestMeasureFailuresAreTyped
//	max-validation      --max-lines is a positive integer                         TestPositive, TestMaxLines
//	(new)               the concurrent walk yields in commit order and stops   TestMeasureAllYieldsInCommitOrderAndStopsAtTheFirstFailure
//	                    at the first failure; a worker panic reaches the caller TestMeasureAllReRaisesAPanicInTheCaller
//	empty-range         EMPTY-RANGE prints and exits 0                            [empty-range]
//	first-parent        the walk is first-parent                                  [merge-first-parent]
//	merge-base-used     the walk starts at merge-base(BASE,HEAD)                  [diverged-uses-merge-base]
//	bad-ref-exit        an unresolvable base ref exits 2                          [base-ref-unknown]

func plan(max int64, commits ...commit) string {
	var b bytes.Buffer
	p := &planner{max: max, out: &b}
	for _, c := range commits {
		p.add(c)
	}
	p.finish()
	return b.String()
}

func c(short string, lines int64) commit {
	return commit{short: short, base: "p" + short, lines: lines}
}

func TestPlannerBoundary(t *testing.T) {
	for _, tc := range []struct {
		name string
		max  int64
		want string
	}{
		{"exactly max fits one slice", 400, "SLICE 1 a..b commits=2 lines=400 base=pa\nPLAN: 1 slice(s) commits=2 lines=400 max=400\n"},
		{"max+1 splits", 399, "SLICE 1 a..a commits=1 lines=200 base=pa\nSLICE 2 b..b commits=1 lines=200 base=pb\nPLAN: 2 slice(s) commits=2 lines=400 max=399\n"},
		{"a commit equal to max is not unsplittable", 200, "SLICE 1 a..a commits=1 lines=200 base=pa\nSLICE 2 b..b commits=1 lines=200 base=pb\nPLAN: 2 slice(s) commits=2 lines=400 max=200\n"},
	} {
		if got := plan(tc.max, c("a", 200), c("b", 200)); got != tc.want {
			t.Errorf("%s:\n got %q\nwant %q", tc.name, got, tc.want)
		}
	}
}

func TestPlannerUnsplittable(t *testing.T) {
	const budget = 400
	for _, tc := range []struct {
		name    string
		commits []commit
		want    string
	}{
		{"middle", []commit{c("a", 50), c("big", 500), c("z", 50)},
			"SLICE 1 a..a commits=1 lines=50 base=pa\nSLICE 2 big..big commits=1 UNSPLITTABLE lines=500 base=pbig\nSLICE 3 z..z commits=1 lines=50 base=pz\nPLAN: 3 slice(s) commits=3 lines=600 max=400\n"},
		{"first", []commit{c("big", 500), c("a", 50)},
			"SLICE 1 big..big commits=1 UNSPLITTABLE lines=500 base=pbig\nSLICE 2 a..a commits=1 lines=50 base=pa\nPLAN: 2 slice(s) commits=2 lines=550 max=400\n"},
		{"last", []commit{c("a", 50), c("big", 500)},
			"SLICE 1 a..a commits=1 lines=50 base=pa\nSLICE 2 big..big commits=1 UNSPLITTABLE lines=500 base=pbig\nPLAN: 2 slice(s) commits=2 lines=550 max=400\n"},
		{"alone", []commit{c("big", 401)},
			"SLICE 1 big..big commits=1 UNSPLITTABLE lines=401 base=pbig\nPLAN: 1 slice(s) commits=1 lines=401 max=400\n"},
		{"max+1 is unsplittable, max is not", []commit{c("a", 400), c("b", 401)},
			"SLICE 1 a..a commits=1 lines=400 base=pa\nSLICE 2 b..b commits=1 UNSPLITTABLE lines=401 base=pb\nPLAN: 2 slice(s) commits=2 lines=801 max=400\n"},
	} {
		if got := plan(budget, tc.commits...); got != tc.want {
			t.Errorf("%s:\n got %q\nwant %q", tc.name, got, tc.want)
		}
	}
}

func TestPlannerFinishFlushesTheLastSlice(t *testing.T) {
	want := "SLICE 1 a..b commits=2 lines=30 base=pa\nPLAN: 1 slice(s) commits=2 lines=30 max=400\n"
	if got := plan(400, c("a", 10), c("b", 20)); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestPlannerGreedyAndZeroLineCommits(t *testing.T) {
	// 4 x 150 at 400 groups 2+2; a zero-line commit (binary only, empty, mode change) joins the open slice
	got := plan(400, c("a", 150), c("b", 150), c("c", 150), c("d", 150), c("e", 0))
	want := "SLICE 1 a..b commits=2 lines=300 base=pa\nSLICE 2 c..e commits=3 lines=300 base=pc\nPLAN: 2 slice(s) commits=5 lines=600 max=400\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := plan(400, c("a", 0)); got != "SLICE 1 a..a commits=1 lines=0 base=pa\nPLAN: 1 slice(s) commits=1 lines=0 max=400\n" {
		t.Errorf("a lone zero-line commit: %q", got)
	}
}

func TestPlannerBinaryField(t *testing.T) {
	bin := func(short string, lines, bin int64) commit {
		return commit{short: short, base: "p", lines: lines, bin: bin}
	}
	got := plan(400, bin("a", 40, 1), bin("b", 5, 2), bin("c", 390, 0))
	want := "SLICE 1 a..b commits=2 lines=45 binary=3 base=p\nSLICE 2 c..c commits=1 lines=390 base=p\nPLAN: 2 slice(s) commits=3 lines=435 max=400 binary=3\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
	got = plan(10, bin("big", 11, 2))
	want = "SLICE 1 big..big commits=1 UNSPLITTABLE lines=11 binary=2 base=p\nPLAN: 1 slice(s) commits=1 lines=11 max=10 binary=2\n"
	if got != want {
		t.Errorf("an unsplittable slice keeps its binary count: got %q want %q", got, want)
	}
	if got := plan(400, c("a", 1)); strings.Contains(got, "binary") {
		t.Errorf("no binary file, no binary= field: %q", got)
	}
}

func TestParseNumstat(t *testing.T) {
	for _, tc := range []struct {
		name       string
		in         string
		lines, bin int64
		ok         bool
	}{
		{"additions and deletions both count", "3\t4\tfile", 7, 0, true},
		{"deletions only", "0\t70\ta", 70, 0, true},
		{"binary rows are typed, not counted", "-\t-\tblob\n3\t4\tf", 7, 1, true},
		{"two binaries", "1\t2\tf\n-\t-\tb1\n-\t-\tb2", 3, 2, true},
		{"a binary row with an empty path is still binary", "-\t-\t", 0, 1, true},
		{"blank records are skipped", "3\t4\tf\n\n5\t6\tg", 18, 0, true},
		{"nothing at all is zero lines", "", 0, 0, true},
		{"a fourth field is allowed", "3\t4\tx\textra", 7, 0, true},
		{"leading zeros are decimal", "007\t3\tx", 10, 0, true},
		{"a CR belongs to the path", "3\t4\tx\r", 7, 0, true},
		{"two fields", "3\t4", 0, 0, false},
		{"garbage", "garbage-row", 0, 0, false},
		{"dash and number", "-\t3\tx", 0, 0, false},
		{"number and dash", "3\t-\tx", 0, 0, false},
		{"leading space", " 3\t4\tx", 0, 0, false},
		{"CR in the count", "3\r\t4\tx", 0, 0, false},
		{"empty count", "5\t\tf", 0, 0, false},
		{"sign", "+5\t4\tf", 0, 0, false},
		{"only tabs", "\t\t", 0, 0, false},
		{"one word", "x", 0, 0, false},
		{"two dashes, two fields", "-\t-", 0, 0, false},
		{"a malformed row after good ones is still malformed", "3\t4\tf\nx", 0, 0, false},
		{"a sum of exactly MaxInt64 is fine", "9223372036854775806\t1\tx", 9223372036854775807, 0, true},
		{"a total of exactly MaxInt64 is fine", "9223372036854775806\t0\tx\n1\t0\ty", 9223372036854775807, 0, true},
		{"a count beyond int64 (git never prints one)", "99999999999999999999\t1\tx", 0, 0, false},
		{"a sum beyond int64", "9223372036854775807\t1\tx", 0, 0, false},
		{"a total beyond int64", "9223372036854775807\t0\tx\n1\t0\ty", 0, 0, false},
	} {
		lines, bin, ok := parseNumstat(tc.in)
		if lines != tc.lines || bin != tc.bin || ok != tc.ok {
			t.Errorf("%s: parseNumstat(%q) = %d, %d, %v; want %d, %d, %v", tc.name, tc.in, lines, bin, ok, tc.lines, tc.bin, tc.ok)
		}
	}
}

func TestPositive(t *testing.T) {
	for v, want := range map[string]bool{"1": true, "400": true, "9223372036854775807": true, "99999999999999999999": true,
		"": false, "0": false, "00": false, "05": false, "007": false, "-5": false, "+5": false, "5x": false, "1.5": false,
		" 5": false, "5 ": false, "5\n": false, "٣": false, "0x10": false, "1e3": false} {
		if got := positive(v); got != want {
			t.Errorf("positive(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestMaxLines(t *testing.T) {
	if n, msg := maxLines("9223372036854775807"); n != 9223372036854775807 || msg != "" {
		t.Errorf("the largest int64 is a valid budget: %d %q", n, msg)
	}
	if _, msg := maxLines("abc"); msg != "plan-review-slices: --max-lines must be a positive integer (got 'abc')" {
		t.Errorf("not a number: %q", msg)
	}
	if _, msg := maxLines("9223372036854775808"); msg != "plan-review-slices: --max-lines must be a positive integer no larger than 9223372036854775807 (got '9223372036854775808')" {
		t.Errorf("beyond int64 is refused, not clamped: %q", msg)
	}
}

// fakeGit answers each git call from a table keyed by the call's first two words; a missing key is a failure.
type fakeGit map[string]string

func (f fakeGit) run(a ...string) (string, bool) {
	k := a[0]
	if len(a) > 1 {
		k += " " + a[1]
	}
	v, ok := f[k]
	return v, ok
}

func TestMeasure(t *testing.T) {
	m, msg := measure(fakeGit{"rev-parse --short=12": "aaaaaaaaaaaa", "rev-list --parents": "A B C", "diff --numstat": "3\t4\tf\n-\t-\tb"}.run, "A")
	if msg != "" || m != (commit{short: "aaaaaaaaaaaa", base: "aaaaaaaaaaaa", lines: 7, bin: 1}) {
		t.Errorf("a commit with a parent: %+v %q", m, msg)
	}
	// the base is the FIRST parent's abbreviation (the one rev-parse printed for it), not the commit's own
	calls := []string{}
	git := func(a ...string) (string, bool) {
		calls = append(calls, strings.Join(a, " "))
		switch a[0] {
		case "rev-parse":
			if a[2] == "C1" {
				return "c1c1c1c1c1c1", true
			}
			return "p1p1p1p1p1p1", true
		case "rev-list":
			return "C1 P1 P2\n", true
		}
		return "1\t1\tf", true
	}
	m, msg = measure(git, "C1")
	if msg != "" || m.short != "c1c1c1c1c1c1" || m.base != "p1p1p1p1p1p1" {
		t.Errorf("base is the first parent: %+v %q", m, msg)
	}
	if want := "diff --numstat P1 C1"; calls[len(calls)-1] != want {
		t.Errorf("the diff is against the first parent: %v", calls)
	}
	// a root commit: base=ROOT and the diff is against the empty tree
	root := fakeGit{"rev-parse --short=12": "rrrrrrrrrrrr", "rev-list --parents": "R", "hash-object -t": "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "diff --numstat": "5\t0\tf"}
	m, msg = measure(root.run, "R")
	if msg != "" || m.base != "ROOT" || m.lines != 5 {
		t.Errorf("a root commit: %+v %q", m, msg)
	}
}

func TestMeasureFailuresAreTyped(t *testing.T) {
	full := fakeGit{"rev-parse --short=12": "ssssssssssss", "rev-list --parents": "A B", "diff --numstat": "1\t1\tf"}
	rootFull := fakeGit{"rev-parse --short=12": "ssssssssssss", "rev-list --parents": "A", "hash-object -t": "tree", "diff --numstat": "1\t1\tf"}
	without := func(f fakeGit, key string) fakeGit {
		g := fakeGit{}
		for k, v := range f {
			if k != key {
				g[k] = v
			}
		}
		return g
	}
	for _, tc := range []struct {
		name string
		git  fakeGit
		want string
	}{
		{"no abbreviation", without(full, "rev-parse --short=12"), "plan-review-slices: cannot abbreviate A"},
		{"parents lookup fails: never a root commit", without(full, "rev-list --parents"), "plan-review-slices: cannot read parents of ssssssssssss"},
		{"empty tree fails for a root commit", without(rootFull, "hash-object -t"), "plan-review-slices: cannot compute the empty tree for root commit ssssssssssss"},
		{"diff fails", without(full, "diff --numstat"), "plan-review-slices: git diff failed for ssssssssssss"},
		{"malformed numstat", fakeGit{"rev-parse --short=12": "ssssssssssss", "rev-list --parents": "A B", "diff --numstat": "garbage-row"}, "plan-review-slices: malformed numstat row for ssssssssssss"},
	} {
		if m, msg := measure(tc.git.run, "A"); msg != tc.want || m != (commit{}) {
			t.Errorf("%s: %+v %q, want %q", tc.name, m, msg, tc.want)
		}
	}
	// the parent's own abbreviation failing is a different, typed failure (the parent is looked up by its sha)
	g := func(a ...string) (string, bool) {
		switch {
		case a[0] == "rev-parse" && a[2] == "A":
			return "ssssssssssss", true
		case a[0] == "rev-list":
			return "A B", true
		}
		return "", false
	}
	if _, msg := measure(g, "A"); msg != "plan-review-slices: cannot abbreviate parent of ssssssssssss" {
		t.Errorf("parent abbreviation: %q", msg)
	}
}

func TestParseArguments(t *testing.T) {
	o, msg := parse(nil)
	if msg != "" || o.cwd != "." || o.base != "origin/main" || o.max != 400 {
		t.Errorf("defaults: %+v %q", o, msg)
	}
	o, msg = parse([]string{"--max-lines", "100", "--base-ref", "x", "--cwd", "d", "--max-lines", "7"})
	if msg != "" || o.cwd != "d" || o.base != "x" || o.max != 7 {
		t.Errorf("the last repeated option wins: %+v %q", o, msg)
	}
	for _, a := range [][]string{{"--cwd"}, {"--base-ref"}, {"--max-lines"}, {"--bogus"}, {"x"}, {"--cwd=d"}, {"--cwd", "d", "--max-lines"}, {"-h"}, {"--help"}} {
		if _, msg := parse(a); msg != usage {
			t.Errorf("parse(%q) = %q, want the usage line", a, msg)
		}
	}
	// the usage fault ends the parse before --max-lines is judged
	if _, msg := parse([]string{"--max-lines", "abc", "--bogus"}); msg != usage {
		t.Errorf("usage before --max-lines: %q", msg)
	}
	if _, msg := parse([]string{"--max-lines", "abc"}); !strings.Contains(msg, "--max-lines must be a positive integer (got 'abc')") {
		t.Errorf("max-lines: %q", msg)
	}
}

func TestGitEnvDropsTheFourRepositorySelectors(t *testing.T) {
	env := []string{"PATH=/x", "GIT_DIR=/a", "GIT_WORK_TREE=/b", "GIT_INDEX_FILE=/c", "GIT_COMMON_DIR=/d", "GIT_CEILING_DIRECTORIES=/e", "GIT_DIRECTORY=/f", "HOME=/h"}
	s := cli.Stdio{Environ: func() []string { return env }, Env: func(string) string { return "" }}
	want := []string{"PATH=/x", "GIT_CEILING_DIRECTORIES=/e", "GIT_DIRECTORY=/f", "HOME=/h"}
	if got := gitEnv(s); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got %v want %v", got, want)
	}
	// a Stdio with no Environ (a golden case) carries only its Env: PATH
	s = cli.Stdio{Env: func(k string) string { return map[string]string{"PATH": "/p"}[k] }}
	if got := gitEnv(s); len(got) != 1 || got[0] != "PATH=/p" {
		t.Errorf("no Environ: %v", got)
	}
}

// measureAll runs the git questions concurrently but yields in commit order and stops at the first failure.
func TestMeasureAllYieldsInCommitOrderAndStopsAtTheFirstFailure(t *testing.T) {
	// c2 answers late and fails; c3 fails at once: the plan must report c2 (the script's sequential walk would have)
	git := func(a ...string) (string, bool) {
		if a[0] == "rev-parse" && a[1] == "--short=12" {
			if a[2] == "c2" {
				time.Sleep(60 * time.Millisecond)
				return "", false
			}
			if a[2] == "c3" {
				return "", false
			}
			return a[2], true
		}
		if a[0] == "rev-list" {
			return a[len(a)-1] + " p", true
		}
		if a[0] == "rev-parse" {
			return "p", true
		}
		return "1\t1\tf", true
	}
	var got []string
	measureAll(git, []string{"c1", "c2", "c3", "c4"}, func(m commit, msg string) bool {
		got = append(got, m.short+"|"+msg)
		return msg == ""
	})
	if want := "c1| |plan-review-slices: cannot abbreviate c2"; strings.Join(got, " ") != want {
		t.Errorf("yielded %q, want %q", got, want)
	}
	// every commit is yielded when nothing fails, in order, whatever the finishing order
	slow := func(a ...string) (string, bool) {
		if a[0] == "rev-parse" && a[1] == "--short=12" {
			if a[2] == "c1" {
				time.Sleep(60 * time.Millisecond)
			}
			return a[2], true
		}
		if a[0] == "rev-list" {
			return a[len(a)-1] + " p", true
		}
		if a[0] == "rev-parse" {
			return "p", true
		}
		return "2\t1\tf", true
	}
	got = nil
	measureAll(slow, []string{"c1", "c2", "c3", "c4", "c5", "c6"}, func(m commit, msg string) bool {
		got = append(got, fmt.Sprintf("%s:%d", m.short, m.lines))
		return true
	})
	if want := "c1:3 c2:3 c3:3 c4:3 c5:3 c6:3"; strings.Join(got, " ") != want {
		t.Errorf("yielded %q, want %q", got, want)
	}
}

func TestMeasureAllReRaisesAPanicInTheCaller(t *testing.T) {
	defer func() {
		if r := recover(); r != "boom" {
			t.Errorf("recovered %v, want the worker's panic", r)
		}
	}()
	measureAll(func(...string) (string, bool) { panic("boom") }, []string{"c1", "c2"}, func(commit, string) bool { return true })
	t.Error("a worker panic must reach the caller")
}
