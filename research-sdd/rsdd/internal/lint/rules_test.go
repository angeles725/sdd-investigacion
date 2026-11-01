package lint

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Findings per fixture (rule:line in output order, WARN/INFO included), pinned from the legacy linter.
var fixtureFindings = map[string]string{
	"blank.md":                "",
	"empty.md":                "",
	"r3-bullets.md":           "R3:5",
	"r3-clean.md":             "",
	"r3-durable2.md":          "",
	"r3-fence-mismatch.md":    "",
	"r3-fence-short.md":       "",
	"r3-fenced.md":            "",
	"r3-first.md":             "R3:7",
	"r3-hashtag.md":           "R3:9",
	"r3-header.md":            "",
	"r3-hyphen.md":            "R3:7 R3:8",
	"r3-inline-cap.md":        "R3:3",
	"r3-inline-fenced.md":     "",
	"r3-inline-selfverify.md": "R3:7 R3:9 R3:15",
	"r3-inline-sep.md":        "R3:3 R3:5 R3:7 R3:9 R3:11",
	"r3-inline-single.md":     "R3:1",
	"r3-inline-waived.md":     "R3:5 R0:7 R3:7",
	"r3-inline.md":            "R3:3 R3:5 R3:7 R3:11 R3:13 R3:27",
	"r3-last.md":              "R3:9",
	"r3-middle.md":            "R3:8",
	"r3-outside.md":           "",
	"r3-prose.md":             "",
	"r3-quoted.md":            "R3:7",
	"r3-scratchpad.md":        "R3:7 R3:8",
	"r3-single.md":            "R3:7",
	"r3-slashtokens.md":       "R3:7 R3:8 R3:9 R3:10 R3:11 R3:12",
	"r3-tilde.md":             "",
	"r3-twocol.md":            "R3:7",
	"r3-unclosed.md":          "WARN:5",
	"r3-words.md":             "R3:7 R3:8 R3:9",
	"r6-bad.md":               "R6:5 R6:9",
	"r6-clean.md":             "",
	"r6-code.md":              "",
	"r6-edges.md":             "R6:1 R6:5",
	"r6-single.md":            "R6:1",
	"r6-split.md":             "",
	"r6-verbs.md":             "R6:3 R6:5 R6:7 R6:9 R6:11",
	"waiver-adjacent.md":      "R3:8",
	"waiver-alias.md":         "R0:8 R3:8",
	"waiver-fenced.md":        "",
	"waiver-malformed.md":     "R0:3",
	"waiver-noreason.md":      "R0:7 R3:7 R0:8 R3:8",
	"waiver-ok.md":            "",
	"waiver-reserved-bad.md":  "R0:7 R0:8 R0:9 R0:10",
	"waiver-reserved.md":      "INFO:7 INFO:8",
	"waiver-unknown.md":       "R0:7 R0:8 R3:8",
	"waiver-wrongrule.md":     "R3:7",
}

var findingRE = regexp.MustCompile(`^(R\d|WARN|INFO) \S+?:(\d+): `)

// parse reduces the command's stdout to the `RULE:line` list the table pins.
func parse(out string) string {
	var got []string
	for _, l := range strings.Split(out, "\n") {
		if m := findingRE.FindStringSubmatch(l); m != nil {
			got = append(got, m[1]+":"+m[2])
		}
	}
	return strings.Join(got, " ")
}

func TestLintBlockFixtureFindings(t *testing.T) {
	fx := fixtures(t)
	for f, want := range fixtureFindings {
		r := goRun(t, fx, "--audit", f)
		if got := parse(r.out); got != want {
			t.Errorf("%s: findings %q, want %q\n%s", f, got, want, r.out)
		}
		if r.rc != 0 {
			t.Errorf("%s: --audit exit %d, want 0", f, r.rc)
		}
		wantRC := 0
		if strings.Contains(" "+want, " R") || f == "empty.md" || f == "blank.md" {
			wantRC = 1
		}
		if fail := goRun(t, fx, f); fail.rc != wantRC {
			t.Errorf("%s: FAIL-mode exit %d, want %d", f, fail.rc, wantRC)
		}
	}
	nonPack := 0
	for _, f := range fixtureFiles(t, fx) {
		if !strings.HasPrefix(f, "pack-") {
			nonPack++
		}
	}
	if len(fixtureFindings) != nonPack {
		t.Errorf("fixture table covers %d files, the fixtures dir has %d non-pack .md files", len(fixtureFindings), nonPack)
	}
}

func TestLintBlockSummaryAndCoverageCounters(t *testing.T) {
	fx := fixtures(t)
	r := goRun(t, fx, "r3-clean.md")
	for _, want := range []string{"NO-MATCH: files were read and inspected; no rule fired", "cert-hw-live-items=5", "selfverify-sections=1", "SUMMARY LINT files=1 empty=0 unreadable=0 findings=0 warn=0 inactive-waivers=0 R0=0 R3=0 R6=0 |"} {
		if !strings.Contains(r.out, want) {
			t.Errorf("clean fixture output lacks %q:\n%s", want, r.out)
		}
	}
	if r.rc != 0 || r.err != "" {
		t.Errorf("rc=%d stderr=%q, want 0 and empty", r.rc, r.err)
	}
	r = goRun(t, fx, "--audit", "corpus")
	for _, want := range []string{"SUMMARY AUDIT files=3 ", "R3=2", "R6=1", "findings=3", "UNCLASSIFIED: 1 non-canonical .md file(s) under corpus were NOT linted (first: corpus/notes.md)"} {
		if !strings.Contains(r.out, want) {
			t.Errorf("corpus output lacks %q:\n%s", want, r.out)
		}
	}
	if strings.Contains(r.out, "notes.md:") {
		t.Errorf("decoy notes.md was linted:\n%s", r.out)
	}
}

func TestLintBlockTypedStates(t *testing.T) {
	fx := fixtures(t)
	dir := t.TempDir()
	write(t, dir, "bad-utf8.md", "bad \xff\xfe bytes\n")
	for _, c := range []struct {
		name string
		args []string
		rc   int
		out  []string
		err  []string
		not  []string
	}{
		{"no args", nil, 2, nil, []string{"usage: lint-block.sh"}, nil},
		{"unknown option", []string{"--bogus", "r3-first.md"}, 2, nil, []string{"lint-block: unknown option: --bogus"}, nil},
		{"help", []string{"-h"}, 0, nil, []string{"usage: lint-block.sh"}, nil},
		{"empty file fails FAIL mode", []string{"empty.md"}, 1, []string{"EMPTY-INPUT empty.md", "empty=1", "EMPTY-INPUT: every given file was empty; nothing was linted"}, nil, []string{"NO-MATCH"}},
		{"blank file", []string{"blank.md"}, 1, []string{"EMPTY-INPUT blank.md"}, nil, nil},
		{"empty next to clean", []string{"empty.md", "r3-clean.md"}, 1, []string{"EMPTY-INPUT: 1 empty file(s) in FAIL mode; a new block must have content"}, nil, []string{"NO-MATCH"}},
		{"audit empty", []string{"--audit", "empty.md"}, 0, []string{"EMPTY-INPUT"}, nil, nil},
		{"absent", []string{"absent.md"}, 2, nil, []string{"ABSENT-INPUT: absent.md does not exist", "lint-block: nothing was linted (see ABSENT-INPUT / DEGRADED above)"}, []string{"SUMMARY"}},
		{"absent + clean is PARTIAL", []string{"absent.md", "r3-clean.md"}, 2, []string{"PARTIAL: "}, []string{"ABSENT-INPUT"}, []string{"NO-MATCH"}},
		{"absent + good still lints", []string{"absent.md", "r3-first.md"}, 2, []string{"R3 r3-first.md:7:"}, []string{"ABSENT-INPUT"}, nil},
		{"undecodable file", []string{filepath.Join(dir, "bad-utf8.md"), "r3-first.md"}, 2, []string{"R3 r3-first.md:7:", "unreadable=1"}, []string{"'utf-8' codec can't decode byte 0xff in position 4: invalid start byte"}, nil},
		{"directory in FAIL mode", []string{"corpus"}, 2, nil, []string{"lint-block: corpus is a directory; FAIL mode takes block files (use --audit for a corpus)"}, nil},
		{"audit empty dir", []string{"--audit", "corpus-empty"}, 0, []string{"EMPTY-INPUT: corpus-empty has no canonical block files", "UNCLASSIFIED: 1"}, nil, []string{"NO-MATCH"}},
		{"audit clean dir", []string{"--audit", "corpus-nomatch"}, 0, []string{"NO-MATCH", "files=1 "}, nil, nil},
		{"audit absent dir", []string{"--audit", "no-such-dir"}, 2, nil, []string{"ABSENT-INPUT"}, nil},
		{"audit file with findings", []string{"--audit", "r3-first.md"}, 0, []string{"R3 r3-first.md:7:"}, nil, nil},
		{"fail clean", []string{"corpus-nomatch/demo-block1.md"}, 0, []string{"SUMMARY LINT"}, nil, nil},
		{"multi-file", []string{"r3-first.md", "r3-last.md", "r6-single.md"}, 1, []string{"R3 r3-first.md:", "R3 r3-last.md:", "R6 r6-single.md:", "files=3"}, nil, nil},
		{"pack needs a name", []string{"--pack"}, 2, nil, []string{"lint-block: --pack needs a name"}, nil},
		{"pack= needs a name", []string{"--pack=", "r3-first.md"}, 2, nil, []string{"lint-block: --pack needs a name"}, nil},
	} {
		r := goRun(t, fx, c.args...)
		if r.rc != c.rc {
			t.Errorf("%s: exit %d, want %d\n%s%s", c.name, r.rc, c.rc, r.out, r.err)
		}
		for _, f := range c.out {
			if !strings.Contains(r.out, f) {
				t.Errorf("%s: stdout lacks %q:\n%s", c.name, f, r.out)
			}
		}
		for _, f := range c.err {
			if !strings.Contains(r.err, f) {
				t.Errorf("%s: stderr lacks %q:\n%s", c.name, f, r.err)
			}
		}
		for _, f := range c.not {
			if strings.Contains(r.out+r.err, f) {
				t.Errorf("%s: output holds %q:\n%s%s", c.name, f, r.out, r.err)
			}
		}
	}
}

func TestLintBlockPrunedNamesAreScannedByBasenameBelowTheRoot(t *testing.T) {
	dir := t.TempDir()
	clean := "# T\n\nplain text\n"
	write(t, dir, ".claude/wt/corpus/a-block1.md", clean)
	write(t, dir, "pruned/node_modules/m/vendored-block1.md", clean)
	write(t, dir, "pruned/.claude/hidden-block2.md", clean)
	write(t, dir, "pruned/real-block3.md", clean)
	if r := goRun(t, dir, "--audit", ".claude/wt/corpus"); !strings.Contains(r.out, "SUMMARY AUDIT files=1 ") {
		t.Errorf("corpus under a .claude ancestor must still be scanned:\n%s", r.out)
	}
	if r := goRun(t, dir, "--audit", "pruned"); !strings.Contains(r.out, "SUMMARY AUDIT files=1 ") || strings.Contains(r.out, "vendored") {
		t.Errorf("node_modules and .claude below the root must be pruned:\n%s", r.out)
	}
}

func TestLintBlockReadOnly(t *testing.T) {
	dir := t.TempDir()
	p := write(t, dir, "x-block1.md", "## Self-verify\n- [CERT-hw] /tmp/x\n")
	before, _ := os.ReadFile(p)
	goRun(t, dir, "--audit", ".")
	goRun(t, dir, "x-block1.md")
	after, _ := os.ReadFile(p)
	ents, _ := os.ReadDir(dir)
	if string(before) != string(after) || len(ents) != 1 {
		t.Errorf("linting changed the tree: %d entries, content equal=%v", len(ents), string(before) == string(after))
	}
}

func TestLintBlockPackRunNeedsPython(t *testing.T) {
	fx := fixtures(t)
	t.Setenv("PATH", t.TempDir())
	if r := goRun(t, fx, "--pack", "jvm", "r3-first.md"); r.rc != 2 || !strings.Contains(r.err, "DEGRADED: python3 not found") || r.out != "" {
		t.Errorf("no python3: %+v, want exit 2, DEGRADED on stderr and nothing linted", r)
	}
	// The core run needs no Python at all: it still lints with an empty PATH.
	if r := goRun(t, fx, "r3-first.md"); r.rc != 1 || !strings.Contains(r.out, "R3 r3-first.md:7:") {
		t.Errorf("core run without python3: %+v", r)
	}
}

// The Python engine is found next to the running binary (<kit>/bin/rsdd -> <kit>/toolbelt/lint_block.py) unless
// LINT_BLOCK_HELPER names it.
func TestLintBlockHelperPath(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(filepath.Dir(filepath.Dir(exe)), "toolbelt", "lint_block.py")
	if got := helperPath(cli.Stdio{Env: func(string) string { return "" }}); got != want {
		t.Errorf("default helper = %q, want %q", got, want)
	}
	env := func(k string) string {
		if k == "LINT_BLOCK_HELPER" {
			return "/x/y.py"
		}
		return ""
	}
	if got := helperPath(cli.Stdio{Env: env}); got != "/x/y.py" {
		t.Errorf("override helper = %q", got)
	}
}

func TestLintBlockPackRunNeedsHelper(t *testing.T) {
	fx := fixtures(t)
	h := filepath.Join(t.TempDir(), "absent.py")
	r := goRunEnv(t, fx, map[string]string{"LINT_BLOCK_HELPER": h}, "--pack", "jvm", "r3-first.md")
	if r.rc != 2 || !strings.Contains(r.err, "DEGRADED: helper "+h+" missing") || r.out != "" {
		t.Errorf("absent helper: %+v", r)
	}
}
