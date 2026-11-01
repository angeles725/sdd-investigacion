package lint

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The rule packs (jvm R1 R5 R7, multi-version R8, native-binary R9, child-gap R4) are Go now (kit issue #2393).
// These tests replace the Python lint-block-packs.test.sh. Every one runs with python3 UNAVAILABLE (an empty PATH):
// a --pack run that still reached for Python would degrade (exit 2) and fail them.

// noPython makes python3 unresolvable for the rest of the test (it must not be parallel).
func noPython(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
}

// taggedLines is the set of 1-based fixture lines matching re, as `3 7 9`.
func taggedLines(t *testing.T, path string, re *regexp.Regexp) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("absent-input: %v", err)
	}
	var got []string
	for i, l := range strings.Split(string(b), "\n") {
		if re.MatchString(l) {
			got = append(got, fmt.Sprint(i+1))
		}
	}
	return strings.Join(got, " ")
}

// reportedLines is the sorted line numbers the output reports for rule in file.
func reportedLines(out, rule, file string) string {
	re := regexp.MustCompile(`(?m)^` + rule + ` \S*` + regexp.QuoteMeta(file) + `:(\d+): `)
	var got []string
	for _, m := range re.FindAllStringSubmatch(out, -1) {
		got = append(got, m[1])
	}
	// numeric order, as `sort -n`
	for i := 1; i < len(got); i++ {
		for j := i; j > 0 && atoi(got[j]) < atoi(got[j-1]); j-- {
			got[j], got[j-1] = got[j-1], got[j]
		}
	}
	return strings.Join(got, " ")
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		n = n*10 + int(c-'0')
	}
	return n
}

type packCase struct {
	name    string
	args    []string // before the fixture
	fixture string
	rule    string         // "" = do not compare lines
	tag     *regexp.Regexp // lines of the fixture the rule must flag exactly
	rc      int
	has     []string // regexps the stdout must match
	hasNot  []string // regexps the stdout must not match
}

func rx(p string) *regexp.Regexp { return regexp.MustCompile(p) }

var packCases = []packCase{
	{name: "no --pack: the pack rules are not enforced and the SUMMARY has no pack fields", fixture: "pack-jvm.md", rc: 1,
		has: []string{`(?m)^R0 `}, hasNot: []string{`packs=`, `R[157]=`, `(?m)^R[157] `}},
	{name: "jvm R1 syntax adoption", args: []string{"--pack", "jvm"}, fixture: "pack-jvm.md", rule: "R1", tag: rx(`R1-`), rc: 1,
		has: []string{`packs=jvm `, `r1-triggers=6(\s|$)`}, hasNot: []string{`inactive-waivers=1`}},
	{name: "jvm R5 permission dispatch", args: []string{"--pack", "jvm"}, fixture: "pack-jvm.md", rule: "R5", tag: rx(`R5-`), rc: 1,
		has: []string{`r5-triggers=3(\s|$)`}},
	{name: "jvm R7 constant inlining", args: []string{"--pack", "jvm"}, fixture: "pack-jvm.md", rule: "R7", tag: rx(`R7-`), rc: 1,
		has: []string{`r7-triggers=5(\s|$)`}},
	{name: "a reason-less R1 waiver is R0 and the R1 finding still fires", args: []string{"--pack", "jvm"}, fixture: "pack-jvm.md", rule: "R0", tag: rx(`R1-NOREASON`), rc: 1},
	{name: "single line without a trailing newline", args: []string{"--pack", "jvm"}, fixture: "pack-single.md", rule: "R1", tag: rx(`.`), rc: 1,
		has: []string{`r5-quoted-skipped=0(\s|$)`}},
	{name: "a pack enforces only its rules: R8 text under --pack jvm stays INFO", args: []string{"--audit", "--pack", "jvm"}, fixture: "pack-r8.md", rc: 0,
		has: []string{`(?m)^INFO .*waiver for inactive pack rule R8`, `inactive-waivers=1`}, hasNot: []string{`(?m)^R8 `}},
	{name: "multi-version R8 baseline attribution", args: []string{"--pack", "multi-version"}, fixture: "pack-r8.md", rule: "R8", tag: rx(`R8-`), rc: 1,
		has: []string{`packs=multi-version`, `r8-triggers=8(\s|$)`}},
	{name: "native-binary R9 evidence floor", args: []string{"--pack", "native-binary"}, fixture: "pack-r9.md", rule: "R9", tag: rx(`R9-`), rc: 1,
		has: []string{`r9-triggers=11(\s|$)`, `(?m)^R9 .*pack-r9.md:\d+: native-binary claim: no sha256`, `no address anchor`, `1 of 2 instruments`}},
	{name: "advisory: CFR is not clearing evidence (R1) and plain 'Access' is not a bypass (R5)", args: []string{"--pack", "jvm"}, fixture: "pack-adv-jvm.md", rule: "R1", tag: rx(`ADV-R1-BAD`), rc: 1},
	{name: "advisory R5", args: []string{"--pack", "jvm"}, fixture: "pack-adv-jvm.md", rule: "R5", tag: rx(`ADV-R5-BAD`), rc: 1},
	{name: "advisory R8", args: []string{"--pack", "multi-version"}, fixture: "pack-adv-r8.md", rule: "R8", tag: rx(`ADV-R8-BAD`), rc: 1},
	{name: "advisory R9", args: []string{"--pack", "native-binary"}, fixture: "pack-adv-r9.md", rule: "R9", tag: rx(`ADV-R9-BAD`), rc: 1},
	{name: "R5 quoted gap text is skipped, an inline cited-absence clears", args: []string{"--pack", "jvm"}, fixture: "pack-r5-quote.md", rule: "R5", tag: rx(`R5Q-[A-Z-]*BAD`), rc: 1,
		has: []string{`r5-quoted-skipped=3(\s|$)`}},
	{name: "calibration R1 prose false positives", args: []string{"--pack", "jvm"}, fixture: "pack-cal-jvm.md", rule: "R1", tag: rx(`CAL-R1-BAD`), rc: 1},
	{name: "calibration R5 auth breadth", args: []string{"--pack", "jvm"}, fixture: "pack-cal-jvm.md", rule: "R5", tag: rx(`CAL-R5-BAD`), rc: 1},
	{name: "calibration R8 negation / question / whether", args: []string{"--pack", "multi-version"}, fixture: "pack-cal-r8.md", rule: "R8", tag: rx(`CAL-R8-BAD`), rc: 1},
	{name: "calibration R9 heading claims judged over their section", args: []string{"--pack", "native-binary"}, fixture: "pack-cal-r9.md", rule: "R9",
		tag: rx(`CAL-R9-(HEADING-|ROW-|EMPTY-|PARENT-)?BAD`), rc: 1, has: []string{`r9-triggers=6(\s|$)`}},
	{name: "child-gap R4 coverage-check / measured-by", args: []string{"--pack", "child-gap"}, fixture: "pack-r4.md", rule: "R4", tag: rx(`R4-`), rc: 1,
		has: []string{`packs=child-gap`, `r4-triggers=14(\s|$)`}},
	{name: "child-gap single bullet", args: []string{"--pack", "child-gap"}, fixture: "pack-r4-single.md", rule: "R4", tag: rx(`R4-`), rc: 1, has: []string{`r4-triggers=1(\s|$)`}},
	{name: "child-gap: no section is a typed zero, not a silent one", args: []string{"--audit", "--pack", "child-gap"}, fixture: "pack-r4-nosection.md", rc: 0,
		has: []string{`R4=0`, `r4-triggers=0 r4-unscoped=1(\s|$)`}},
	{name: "R4 is opt-in", args: []string{"--pack", "jvm"}, fixture: "pack-r4.md", rule: "R4", rc: 0, has: []string{`inactive-waivers=1`, `NO-MATCH`}},
	{name: "R4 section model", args: []string{"--pack", "child-gap"}, fixture: "pack-r4-scope.md", rule: "R4", tag: rx(`R4-`), rc: 1,
		has: []string{`r4-triggers=5(\s|$)`, `r4-unscoped=4(\s|$)`}},
	{name: "no r4 fields without the child-gap pack", args: []string{"--audit", "--pack", "jvm"}, fixture: "pack-r4-scope.md", rc: 0, hasNot: []string{`r4-unscoped`}},
	{name: "R4 clause grammar", args: []string{"--pack", "child-gap"}, fixture: "pack-r4-clause.md", rule: "R4", tag: rx(`R4-`), rc: 1,
		has: []string{`r4-triggers=18(\s|$)`, `r4-unscoped=0(\s|$)`, `child gap B65-G2: MALFORMED .*placeholder`, `child gap B65-G5: MEASURE - states 247`,
			`child gap B65-G6: MALFORMED .*no result`, `child gap B65-G7: MEASURE - states 12\.5%`, `child gap B65-G9: MEASURE - states 3k`}},
	{name: "R4 section model round two", args: []string{"--pack", "child-gap"}, fixture: "pack-r4-scope2.md", rule: "R4", tag: rx(`R4-`), rc: 1,
		has: []string{`r4-triggers=3(\s|$)`, `r4-unscoped=2(\s|$)`}},
}

func TestLintPackFixtures(t *testing.T) {
	noPython(t)
	fx := fixtures(t)
	for _, c := range packCases {
		r := goRun(t, fx, append(append([]string(nil), c.args...), c.fixture)...)
		if r.rc != c.rc {
			t.Errorf("%s: rc = %d, want %d (stderr %q)", c.name, r.rc, c.rc, r.err)
		}
		if c.rule != "" {
			want := ""
			if c.tag != nil {
				want = taggedLines(t, filepath.Join(fx, c.fixture), c.tag)
				if want == "" {
					t.Fatalf("%s: tag matches no line of %s", c.name, c.fixture)
				}
			}
			if got := reportedLines(r.out, c.rule, c.fixture); got != want {
				t.Errorf("%s: %s flagged on lines [%s], want [%s]\n%s", c.name, c.rule, got, want, r.out)
			}
		}
		for _, p := range c.has {
			if !regexp.MustCompile(p).MatchString(r.out) {
				t.Errorf("%s: output lacks /%s/\n%s", c.name, p, r.out)
			}
		}
		for _, p := range c.hasNot {
			if regexp.MustCompile(p).MatchString(r.out) {
				t.Errorf("%s: output has /%s/\n%s", c.name, p, r.out)
			}
		}
	}
}

// All four packs together, comma lists, the --pack= form and a repeated pack (each loads once, in order).
func TestLintPackLoadForms(t *testing.T) {
	noPython(t)
	fx := fixtures(t)
	r := goRun(t, fx, "--audit", "--pack", "jvm,multi-version", "--pack=native-binary", "--pack", "jvm", "pack-single.md")
	if r.rc != 0 || !strings.Contains(r.out, "packs=jvm,multi-version,native-binary r1-triggers=") {
		t.Errorf("forms: %+v", r)
	}
	if !strings.Contains(r.out, " R0=0 R3=0 R6=0 R1=1 R5=0 R7=0 R8=0 R9=0 ") {
		t.Errorf("per-rule counters follow load order: %s", r.out)
	}
	r = goRun(t, fx, "--audit", "--pack", "child-gap", "--pack", "jvm", "pack-r4-scope.md")
	if !strings.Contains(r.out, "packs=child-gap,jvm r4-triggers=5 r1-triggers=0 r5-triggers=0 r7-triggers=0 r4-unscoped=4 r5-quoted-skipped=0") {
		t.Errorf("trigger fields in load order, suffix counters sorted by key: %s", r.out)
	}
}

// A pack that cannot load is exit 2 with NOTHING linted, never a silent core-only run.
func TestLintPackLoaderErrors(t *testing.T) {
	noPython(t)
	fx := fixtures(t)
	avail := "available: child-gap, jvm, multi-version, native-binary"
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--pack", "nosuch", "pack-jvm.md"}, "lint-block: unknown pack nosuch (" + avail + ")\n"},
		{[]string{"--pack", "Bad_Name", "pack-jvm.md"}, "lint-block: invalid pack name 'Bad_Name' (lower-case letters, digits and '-' only)\n"},
		{[]string{"--pack", "../x", "pack-jvm.md"}, "lint-block: invalid pack name '../x' (lower-case letters, digits and '-' only)\n"},
		{[]string{"--pack", "-x", "pack-jvm.md"}, "lint-block: --pack needs a name\n"},
		{[]string{"--pack", "", "pack-jvm.md"}, "lint-block: --pack needs a name\n"},
		{[]string{"--pack", ",", "pack-jvm.md"}, "lint-block: --pack needs a name\n"},
		{[]string{"--pack", ",,", "pack-jvm.md"}, "lint-block: --pack needs a name\n"},
		{[]string{"--pack=,", "pack-jvm.md"}, "lint-block: --pack needs a name\n"},
		{[]string{"pack-jvm.md", "--pack"}, "lint-block: --pack needs a name\n"},
		{[]string{"--pack", "jvm,nosuch", "pack-jvm.md"}, "lint-block: unknown pack nosuch (" + avail + ")\n"},
		{[]string{"--pack", "a b", "pack-jvm.md"}, "lint-block: invalid pack name 'a b' (lower-case letters, digits and '-' only)\n"},
		{[]string{"--pack", "jvm\n", "pack-jvm.md"}, "lint-block: unknown pack jvm\n (" + avail + ")\n"},
		{[]string{"--audit", "--pack", "nosuch", "corpus-empty"}, "lint-block: unknown pack nosuch (" + avail + ")\n"},
		{[]string{"--pack", "J", "--pack", "nosuch", "pack-jvm.md"}, "lint-block: invalid pack name 'J' (lower-case letters, digits and '-' only)\n"},
	} {
		r := goRun(t, fx, c.args...)
		if r.rc != 2 || r.err != c.want || r.out != "" {
			t.Errorf("%q: rc=%d err=%q out=%q, want rc 2, err %q and nothing linted", c.args, r.rc, r.err, r.out, c.want)
		}
	}
}

func TestLintPackLinterLoad(t *testing.T) {
	lt := newLinter()
	if err := lt.loadPacks([]string{"jvm", "jvm", "multi-version"}); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(lt.ids, ","); got != "R3,R6,R1,R5,R7,R8" {
		t.Errorf("rule ids = %s", got)
	}
	if got := strings.Join(lt.loaded, ","); got != "jvm,multi-version" {
		t.Errorf("loaded = %s", got)
	}
	if err := lt.loadPacks([]string{"native-binary", "nope"}); err == nil || err.Error() != "unknown pack nope (available: child-gap, jvm, multi-version, native-binary)" {
		t.Errorf("unknown pack error = %v", err)
	}
	if got := strings.Join(packNames(), ","); got != "child-gap,jvm,multi-version,native-binary" {
		t.Errorf("packNames = %s", got)
	}
	// ids are validated against the reserved set and against the active ones (a pack cannot take R3 or repeat an id)
	if err := newLinter().register("demo", []packRule{{"R3", nil}}); err == nil || err.Error() != "pack demo: rule R3 is already active" {
		t.Errorf("collision error = %v", err)
	}
	if err := newLinter().register("demo", []packRule{{"R42", nil}}); err == nil || err.Error() != "pack demo: R42 is not a reserved pack rule id (R1, R2, R4, R5, R7, R8, R9)" {
		t.Errorf("reserved error = %v", err)
	}
	if err := newLinter().register("demo", nil); err == nil || err.Error() != "pack demo registered no rules" {
		t.Errorf("empty pack error = %v", err)
	}
}

// A rule that panics is an operational failure (RULE-CRASH, exit 2), never "findings" and never a clean zero.
func TestLintPackRuleCrash(t *testing.T) {
	lt := newLinter()
	lt.rules = append(lt.rules, packRule{"R1", func(*doc) []finding { panic("boom") }})
	lt.ids = append(lt.ids, "R1")
	res, crash := lt.lint("# x\n")
	if crash != "boom" || len(res.findings) != 0 {
		t.Errorf("crash = %q, findings = %v", crash, res.findings)
	}
	if _, crash := newLinter().lint("# x\n"); crash != "" {
		t.Errorf("a healthy run reported a crash: %q", crash)
	}
}

// With a pack loaded, a waiver naming an unknown rule lists the ACTIVE ids in load order, and a waiver for a now-active
// pack id is no longer inactive.
func TestLintPackWaiverActiveIDs(t *testing.T) {
	noPython(t)
	dir := t.TempDir()
	write(t, dir, "w-block1.md", "<!-- lint-waive: R42 reason=x -->\n\n<!-- lint-waive: R8 reason=y -->\n\n<!-- lint-waive: R1 reason=z -->\n")
	r := goRun(t, dir, "--audit", "--pack", "jvm,multi-version", "w-block1.md")
	if !strings.Contains(r.out, "waiver names unknown rule R42 (active: R3, R6, R1, R5, R7, R8); it does NOT waive") {
		t.Errorf("active list: %s", r.out)
	}
	if !strings.Contains(r.out, "inactive-waivers=0") {
		t.Errorf("R8 and R1 are active here: %s", r.out)
	}
	r = goRun(t, dir, "--audit", "w-block1.md")
	if !strings.Contains(r.out, "(active: R3, R6)") || !strings.Contains(r.out, "inactive-waivers=2") {
		t.Errorf("core only: %s", r.out)
	}
}

// Packs read the document the core already parsed: a pack run over a directory and a file list lints the same blocks
// and keeps the read-only contract.
func TestLintPackCorpusAndPartial(t *testing.T) {
	noPython(t)
	fx := fixtures(t)
	r := goRun(t, fx, "--audit", "--pack", "jvm", "absent.md", "pack-jvm.md")
	if r.rc != 2 || !strings.Contains(r.err, "ABSENT-INPUT: absent.md does not exist") || !strings.Contains(r.out, "packs=jvm") {
		t.Errorf("partial: %+v", r)
	}
	r = goRun(t, fx, "--audit", "--pack", "jvm", "--pack", "multi-version", "corpus")
	if r.rc != 0 || !strings.Contains(r.out, "SUMMARY AUDIT files=") || !strings.Contains(r.out, "packs=jvm,multi-version ") {
		t.Errorf("corpus: %+v", r)
	}
}

// RED: this fails on a Python-delegating SUT (python3 not found), which is what the port removes.
func TestLintPackNeedsNoPython(t *testing.T) {
	noPython(t)
	fx := fixtures(t)
	r := goRun(t, fx, "--pack", "jvm", "pack-single.md")
	if r.rc != 1 || r.err != "" || !strings.Contains(r.out, "R1 pack-single.md:1: ") {
		t.Errorf("--pack run without python3: %+v", r)
	}
}
