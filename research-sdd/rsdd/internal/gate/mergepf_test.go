package gate

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The workflow fixtures are the bash suite's own, read in place.
var mgFixtures = kitroot.Must() + "/toolbelt/tests/fixtures/merge-gate"

func wfFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(mgFixtures, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

const wfPath = ".github/workflows/toolbelt-tests.yml"

func filesJSON(names ...string) string {
	var es []string
	for _, n := range names {
		es = append(es, fmt.Sprintf(`{"status":"added","filename":%q}`, n))
	}
	return "[" + strings.Join(es, ",") + "]"
}

// pfRun is a --merge run whose required checks never reported, so the path filters decide. base and head are
// workflow fixture names (or inline text when they contain a newline) at the PR base tree and the head tree.
func pfRun(t *testing.T, base, head string, files string, tweak ...func(*scn)) (string, int, *scn) {
	t.Helper()
	sc := newScn(t)
	text := func(n string) string {
		if strings.Contains(n, "\n") {
			return n
		}
		return wfFixture(t, n)
	}
	sc.workflows = map[string]map[string]string{hPRBase: {wfPath: text(base)}, hHead: {wfPath: text(head)}}
	sc.checks = runsJSON("pr-validation:completed:success")
	sc.files = files
	for _, f := range tweak {
		f(sc)
	}
	out, _, rc := sc.run(mergeArgs7()...)
	return out, rc, sc
}

const (
	skipNote  = "merge-gate: note: required check %s skipped by path filter (%s pull_request.paths matches none of the %d changed files)\n"
	missingCI = "merge-gate: refuse: ci_missing (shellcheck,toolbelt-tests) (head=" + hHead + ") — CI for this exact head must be green before merging\n"
)

func notEval(chk, why string) string {
	return "merge-gate: note: required check " + chk + " not evaluated against path filters: " + why + "; stays required\n"
}

func TestPathFilterSkips(t *testing.T) {
	allow := allowLine("passive", bound7)
	merged := "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	both := func(wf string, n int) string {
		return fmt.Sprintf(skipNote, "shellcheck", wf, n) + fmt.Sprintf(skipNote, "toolbelt-tests", wf, n)
	}
	t.Run("docs-only diff: both filtered checks absent -> merges with two notes", func(t *testing.T) {
		out, rc, sc := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("odd/tasks/x.md", "docs/yy.md"))
		if out != both(wfPath, 2)+allow+merged || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		if !sc.called("gh api repos/{owner}/{repo}/pulls/7/files?per_page=100 --paginate") {
			t.Fatal("the PR files are read")
		}
	})
	t.Run("nothing missing: the files are never read", func(t *testing.T) {
		_, rc, sc := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("docs/yy.md"), func(sc *scn) {
			sc.checks = runsJSON("shellcheck:completed:success", "toolbelt-tests:completed:success")
		})
		if rc != 0 || sc.called("gh api repos/{owner}/{repo}/pulls/7/files") {
			t.Fatalf("rc=%d calls=%v", rc, sc.calls)
		}
	})
	t.Run("the base tree is judged too: head narrowing its own paths cannot exempt it", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-narrow.yml", filesJSON("research-sdd/toolbelt/merge-gate.sh"))
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("base and head both skip", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-narrow.yml", "wf-narrow.yml", filesJSON("research-sdd/toolbelt/merge-gate.sh"))
		if out != both(wfPath, 1)+allow+merged || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	matches := []struct {
		name, file string
		skip       bool
	}{
		{"toolbelt diff runs", "research-sdd/toolbelt/x.sh", false},
		{"exact-file pattern matches", "research-sdd/METHODOLOGY.md", false},
		{"patterns are anchored at the end and . is literal", "research-sdd/METHODOLOGY.mdx", true},
		{". in a pattern is literal", "research-sdd/METHODOLOGYxmd", true},
		{"patterns are anchored at the root", "x/research-sdd/toolbelt/y.sh", true},
		{"* does not cross directories", "configs/a/b.cfg", true},
		{"* matches within one directory", "configs/a.cfg", false},
		{"** crosses directories (single-quoted pattern)", "tools/a/b/c.py", false},
		{"the trailing /** needs the directory", "tools", true},
		{"a push-only pattern does not count", "research-sdd/push-only/a.sh", true},
		{"a late pattern matches", "docs/yy.md", true},
	}
	for _, m := range matches {
		t.Run(m.name, func(t *testing.T) {
			out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON(m.file))
			if m.skip {
				if out != both(wfPath, 1)+allow+merged || rc != 0 {
					t.Fatalf("out=%q rc=%d", out, rc)
				}
			} else if out != missingCI || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		})
	}
	for pos, files := range [][]string{{"tools/gen.py", "docs/a.md", "odd/b.md"}, {"docs/a.md", "tools/gen.py", "odd/b.md"}, {"docs/a.md", "odd/b.md", "tools/gen.py"}} {
		t.Run(fmt.Sprintf("mixed diff, matching file at %d", pos), func(t *testing.T) {
			out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON(files...))
			if out != missingCI || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		})
	}
	t.Run("a renamed file counts under its previous name", func(t *testing.T) {
		files := `[{"status":"renamed","filename":"docs/new.md","previous_filename":"tools/old.py"}]`
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", files)
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("the note counts every listed name", func(t *testing.T) {
		files := `[{"status":"renamed","filename":"docs/new.md","previous_filename":"odd/old.md"}]`
		out, _, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", files)
		if !strings.HasPrefix(out, fmt.Sprintf(skipNote, "shellcheck", wfPath, 2)) {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("the real workflow copy", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-real-toolbelt-tests.yml", "wf-real-toolbelt-tests.yml", filesJSON("odd/tasks/x.md", "docs/yy.md"))
		if out != both(wfPath, 2)+allow+merged || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		out, rc, _ = pfRun(t, "wf-real-toolbelt-tests.yml", "wf-real-toolbelt-tests.yml", filesJSON("research-sdd/toolbelt/merge-gate.sh"))
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		out, rc, _ = pfRun(t, "wf-real-toolbelt-tests.yml", "wf-real-toolbelt-tests.yml", filesJSON("research-sdd/profiles/p.md"))
		if out != missingCI || rc != 1 {
			t.Fatalf("a pattern late in the list: out=%q rc=%d", out, rc)
		}
	})
	t.Run("4-space indentation is parsed", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-jobs4.yml", "wf-jobs4.yml", filesJSON("docs/yy.md"))
		if out != both(wfPath, 1)+allow+merged || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		out, rc, _ = pfRun(t, "wf-jobs4.yml", "wf-jobs4.yml", filesJSON("research-sdd/toolbelt/x.sh"))
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("a push-only pattern file list", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("research-sdd/push-only/a.sh"))
		if rc != 0 || !strings.HasPrefix(out, fmt.Sprintf(skipNote, "shellcheck", wfPath, 1)) {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("one filtered check absent, the other reported: a reported check is judged on its result", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("docs/yy.md"), func(sc *scn) {
			sc.checks = runsJSON("pr-validation:completed:success", "toolbelt-tests:completed:success")
		})
		if out != fmt.Sprintf(skipNote, "shellcheck", wfPath, 1)+allow+merged || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		out, rc, _ = pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("docs/yy.md"), func(sc *scn) {
			sc.checks = runsJSON("pr-validation:completed:success", "toolbelt-tests:completed:failure")
		})
		if !strings.Contains(out, "merge-gate: refuse: ci_failed (toolbelt-tests)") || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		for _, c := range []struct{ run, want string }{
			{"pr-validation:completed:failure", "ci_failed (pr-validation)"},
			{"pr-validation:in_progress:", "ci_pending (pr-validation)"},
		} {
			out, rc, _ = pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("docs/yy.md"), func(sc *scn) { sc.checks = runsJSON(c.run) })
			if !strings.Contains(out, "merge-gate: refuse: "+c.want) || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		}
	})
}

func TestPathFilterUnknowns(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	const wf = wfPath
	cases := []struct {
		name, fixture string
		files         string
		why           string // the reason shared by both checks; "" = the check should have run, no note
	}{
		{"paths-ignore", "wf-ignore.yml", docs, wf + " uses paths-ignore (head tree)"},
		{"negated pattern", "wf-negation.yml", docs, wf + " has an unsupported path pattern (!research-sdd/docs/**, head tree)"},
		{"no paths filter always runs", "wf-nofilter.yml", docs, ""},
		{"no pull_request trigger", "wf-push-only.yml", docs, "no pull_request trigger in " + wf + " (head tree)"},
		{"quoted job id", "wf-quoted-id.yml", docs, "cannot parse the jobs of " + wf + " (job key shape: \"toolbelt-tests\":, head tree)"},
		{"job name expression", "wf-name-expr.yml", docs, "cannot parse the jobs of " + wf + " (job name shape of lint, head tree)"},
		{"flow-style jobs", "wf-jobs-flow.yml", docs, "cannot parse the jobs of " + wf + " (jobs is not a block mapping, head tree)"},
		{"pull_request_target", "wf-prt.yml", docs, wf + " has another PR-like trigger (pull_request_target trigger, head tree)"},
		{"merge_group", "wf-merge-group.yml", docs, wf + " has another PR-like trigger (merge_group trigger, head tree)"},
		{"inline on", "wf-inline.yml", docs, wf + " has another PR-like trigger (pull_request or merge_group inside an inline on: value, head tree)"},
		{"no changed files", "wf-paths.yml", `[]`, "the PR reports no changed files"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, rc, _ := pfRun(t, tc.fixture, tc.fixture, tc.files)
			want := missingCI
			if tc.why != "" {
				want = notEval("shellcheck", tc.why) + notEval("toolbelt-tests", tc.why) + missingCI
			}
			if out != want || rc != 1 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
			}
		})
	}
	// every pattern form the matcher does not emulate exactly is reported, never guessed
	for _, pat := range []string{"**/x.md", "a/**/b", "docs/[a-z]*.md", "docs/+x", "docs/{a,b}", "**.md", "docs/**/x", "docs/a b", "docs/?.md", "docs/a?"} {
		t.Run("unsupported pattern "+pat, func(t *testing.T) {
			wfText := "name: t\non:\n  pull_request:\n    paths:\n      - \"" + pat + "\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n"
			out, rc, _ := pfRun(t, wfText, wfText, docs)
			why := wf + " has an unsupported path pattern (" + pat + ", head tree)"
			want := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
			if out != want || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		})
	}
	t.Run("the first unsupported pattern is the one named, a later match still counts", func(t *testing.T) {
		wfText := "on:\n  pull_request:\n    paths:\n      - \"**/x\"\n      - \"docs/**\"\njobs:\n  toolbelt-tests:\n    runs-on: x\n  shellcheck:\n    runs-on: x\n"
		out, rc, _ := pfRun(t, wfText, wfText, docs)
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("a PR that changes a workflow is never evaluated", func(t *testing.T) {
		for _, files := range [][]string{
			{".github/workflows/toolbelt-tests.yml", "odd/a.md", "odd/b.md"},
			{"odd/a.md", ".github/workflows/other.yml", "odd/b.md"},
			{"odd/a.md", "odd/b.md", ".github/workflows/new.yml"},
		} {
			out, rc, _ := pfRun(t, "wf-narrow.yml", "wf-narrow.yml", filesJSON(files...))
			why := "the PR changes .github/workflows (its own filters cannot exempt it)"
			if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		}
		out, rc, _ := pfRun(t, "wf-narrow.yml", "wf-narrow.yml", filesJSON(".githubx/workflows/a.yml", "odd/a.md"))
		if rc != 0 || !strings.Contains(out, "skipped by path filter") {
			t.Fatalf("a look-alike directory does not trigger the guard: %q", out)
		}
	})
	t.Run("3000 changed files is the API cap, 2999 is not", func(t *testing.T) {
		mk := func(n int) string {
			var names []string
			for i := 0; i < n; i++ {
				names = append(names, fmt.Sprintf("odd/f%d.md", i))
			}
			return filesJSON(names...)
		}
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", mk(3000))
		why := "the PR lists 3000 changed files (GitHub caps the files list at 3000, so it may be truncated)"
		if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		out, rc, _ = pfRun(t, "wf-paths.yml", "wf-paths.yml", mk(2999))
		if rc != 0 || !strings.Contains(out, "none of the 2999 changed files") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("unreadable PR files: one note, then stop", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", "", func(sc *scn) {
			sc.ghAns["api repos/o/r/pulls/7/files?per_page=100"] = failWith(1, "")
			sc.ghAns["api repos/{owner}/{repo}/pulls/7/files?per_page=100"] = failWith(1, "")
		})
		note := "merge-gate: note: path filters not evaluated: cannot read the files of PR #7 (gh api failed or unparseable); missing required checks stay ci_missing\n"
		if out != note+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	for name, files := range map[string]string{"malformed": "{nope", "not an array": `{"a":1}`, "an entry that is not an object": `[3]`, "empty": ""} {
		t.Run("unparseable PR files: "+name, func(t *testing.T) {
			out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", files)
			if !strings.HasPrefix(out, "merge-gate: note: path filters not evaluated: cannot read the files") || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		})
	}
	t.Run("a required name no workflow job carries is never skippable", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", docs, func(sc *scn) {
			sc.environ = append(sc.environ, "MERGE_GATE_REQUIRED_CHECKS=shellcheck,nope")
		})
		want := fmt.Sprintf(skipNote, "shellcheck", wfPath, 1) + notEval("nope", "no workflow job named nope in the head tree") +
			"merge-gate: refuse: ci_missing (nope) (head=" + hHead + ") — CI for this exact head must be green before merging\n"
		if out != want || rc != 1 {
			t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
		}
	})
	t.Run("no workflows in the head tree", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", docs, func(sc *scn) { sc.workflows[hHead] = nil })
		why := "no workflow files in the head tree (.github/workflows)"
		if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("an unreadable workflow entry", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", docs, func(sc *scn) {
			sc.workflows[hHead][".github/workflows/zz-sub.yml"] = ""
			sc.showFail[hHead+":.github/workflows/zz-sub.yml"] = true
		})
		why := "cannot read .github/workflows/zz-sub.yml in the head tree"
		if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("a base tree without the workflow is unknown", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", docs, func(sc *scn) { sc.workflows[hPRBase] = nil })
		why := "no workflow files in the base tree (.github/workflows)"
		if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("a carrier that skips next to one that runs", func(t *testing.T) {
		for _, order := range [][2]string{{"wf-paths.yml", "wf-docs-paths.yml"}, {"wf-docs-paths.yml", "wf-paths.yml"}} {
			out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", `[{"status":"added","filename":"docs/yy.md"}]`, func(sc *scn) {
				for _, tree := range []string{hHead, hPRBase} {
					sc.workflows[tree] = map[string]string{
						".github/workflows/a-first.yml": wfFixture(t, order[0]),
						".github/workflows/z-last.yml":  wfFixture(t, order[1]),
					}
				}
			})
			if out != missingCI || rc != 1 {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		}
	})
	t.Run("every carrier skipping names them all", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("odd/x.md"), func(sc *scn) {
			for _, tree := range []string{hHead, hPRBase} {
				sc.workflows[tree] = map[string]string{
					".github/workflows/a-first.yml": wfFixture(t, "wf-paths.yml"),
					".github/workflows/z-last.yml":  wfFixture(t, "wf-paths.yml"),
				}
			}
		})
		wfs := ".github/workflows/a-first.yml,.github/workflows/z-last.yml"
		want := fmt.Sprintf(skipNote, "shellcheck", wfs, 1) + fmt.Sprintf(skipNote, "toolbelt-tests", wfs, 1) + allowLine("passive", bound7) +
			"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
		if out != want || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("only .yml and .yaml files are workflows", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", docs, func(sc *scn) {
			sc.workflows[hHead][".github/workflows/notes.txt"] = "jobs: [broken"
			sc.workflows[hHead][".github/workflows/x.yaml"] = wfFixture(t, "wf-narrow.yml")
		})
		wfs := ".github/workflows/toolbelt-tests.yml,.github/workflows/x.yaml"
		if rc != 0 || !strings.Contains(out, "skipped by path filter ("+wfs+" pull_request.paths matches none of the 1 changed files)") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}
