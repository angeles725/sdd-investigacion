package gate

import (
	"strings"
	"testing"
)

// Kit issue #2852: a workflow job whose `name:` the reader cannot expand voids the path-filter evaluation of a
// required check only when that name COULD equal the check. These tests drive the rule end to end (pfRun) and
// through pfScanWorkflow; wf-real-rsdd-go.yml is a copy of the real .github/workflows/rsdd-go.yml (the matrix job
// rsdd-go-bridge with its conditional `name:` expression, the shape that blocked PR #2850). merge-gate.test.sh case 5d
// keeps it byte-equal to the live file, like wf-real-toolbelt-tests.yml (case 5).

const (
	wfPR      = ".github/workflows/pr-check.yml"
	wfRsddGo  = ".github/workflows/rsdd-go.yml"
	pfWFHead  = "name: t\non:\n  pull_request:\n    paths:\n      - \"nothing-here/**\"\njobs:\n"
	pfJobTool = "  toolbelt-tests:\n    runs-on: x\n"
	pfJobShel = "  shellcheck:\n    runs-on: x\n"
)

// pfNamed is a job whose name: is the given raw YAML value.
func pfNamed(id, rawName string) string {
	return "  " + id + ":\n    name: " + rawName + "\n    runs-on: x\n"
}

// realSet puts the real workflow set (toolbelt-tests, pr-check, rsdd-go) in both the PR base tree and the head tree.
func realSet(t *testing.T) func(*scn) {
	return func(sc *scn) {
		for _, tree := range []string{hHead, hPRBase} {
			sc.workflows[tree] = map[string]string{
				wfPath:   wfFixture(t, "wf-real-toolbelt-tests.yml"),
				wfPR:     wfFixture(t, "wf-real-pr-check.yml"),
				wfRsddGo: wfFixture(t, "wf-real-rsdd-go.yml"),
			}
		}
	}
}

func TestPathFilterTemplatedJobNameRealWorkflows(t *testing.T) {
	merged := "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	t.Run("a docs-only PR is evaluated against the real workflow set: both skipped checks are accepted", func(t *testing.T) {
		out, rc, sc := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("odd/tasks/x.md", "docs/yy.md"), realSet(t))
		want := strings.Join([]string{
			"merge-gate: note: required check shellcheck skipped by path filter (" + wfPath + " pull_request.paths matches none of the 2 changed files)\n",
			"merge-gate: note: required check toolbelt-tests skipped by path filter (" + wfPath + " pull_request.paths matches none of the 2 changed files)\n",
		}, "") + allowLine("passive", bound7) + merged
		if out != want || rc != 0 {
			t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
		}
		if !sc.called("gh api repos/{owner}/{repo}/pulls/7/files?per_page=100 --paginate") {
			t.Fatal("the PR files are read")
		}
	})
	t.Run("a diff the toolbelt filter matches still needs its checks", func(t *testing.T) {
		out, rc, _ := pfRun(t, "wf-paths.yml", "wf-paths.yml", filesJSON("research-sdd/toolbelt/x.sh"), realSet(t))
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}

func TestPathFilterTemplatedJobNameCouldBeTheCheck(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	const wf = wfPath
	// name: values whose expansion could equal shellcheck; bothChecks marks the ones that could equally be toolbelt-tests
	couldBeShellcheck := []struct {
		name, raw  string
		bothChecks bool
	}{
		{"no literal part", "${{ matrix.n }}", true},
		{"literal prefix of the check", "shell${{ matrix.n }}", false},
		{"literal suffix of the check", "${{ matrix.n }}check", false},
		{"prefix and suffix around one expression", "sh${{ matrix.n }}ck", false},
		{"two expressions, literal parts in order", "shell${{ matrix.a }}c${{ matrix.b }}k", false},
		{"conditional whose first branch is the check", "${{ matrix.s == 0 && 'shellcheck' || format('x ({0})', matrix.s) }}", false},
		{"conditional whose fallback is the check", "${{ matrix.s == 0 && 'other' || 'shellcheck' }}", false},
		{"format whose template can be the check", "${{ format('{0}check', matrix.n) }}", false},
		{"unknown fallback", "${{ matrix.s == 0 && 'rsdd-go-bridge' || matrix.name }}", true},
		{"unknown context", "${{ github.ref }}", true},
		{"unterminated expression", "shell${{ matrix.n", true},
		{"unterminated string in the expression", "${{ 'shellcheck }}", true},
		{"block scalar", ">-", true},
		{"empty name", `""`, true},
	}
	for _, tc := range couldBeShellcheck {
		t.Run(tc.name, func(t *testing.T) {
			wfText := pfWFHead + pfJobTool + pfNamed("lint", tc.raw)
			out, rc, _ := pfRun(t, wfText, wfText, docs)
			why := "cannot parse the jobs of " + wf + " (job name shape of lint, head tree)"
			want := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
			if !tc.bothChecks {
				// shellcheck stays unevaluated; the name cannot be toolbelt-tests, so that check is judged (skipped here)
				want = notEval("shellcheck", why) +
					"merge-gate: note: required check toolbelt-tests skipped by path filter (" + wf + " pull_request.paths matches none of the 1 changed files)\n" +
					"merge-gate: refuse: ci_missing (shellcheck) (head=" + hHead + ") — CI for this exact head must be green before merging\n"
			}
			if out != want || rc != 1 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
			}
		})
	}
	// name: values whose expansion can never equal shellcheck or toolbelt-tests: the evaluation goes on
	cannot := []struct{ name, raw string }{
		{"literal prefix and suffix that fit neither", "rsdd-go-bridge (${{ matrix.shard }}/3)"},
		{"literal suffix that is not a suffix of either", "${{ matrix.n }}-bridge"},
		{"literal prefix that is a prefix of neither", "bridge-${{ matrix.n }}"},
		{"literal parts in the wrong order", "k${{ matrix.n }}shell"},
		{"a middle literal absent from both", "${{ matrix.a }}zzz${{ matrix.b }}"},
		{"the real rsdd-go-bridge conditional", "${{ matrix.shard == 0 && 'rsdd-go-bridge' || format('rsdd-go-bridge ({0}/3)', matrix.shard) }}"},
		{"quoted real conditional", "\"${{ matrix.shard == 0 && 'rsdd-go-bridge' || format('rsdd-go-bridge ({0}/3)', matrix.shard) }}\""},
		{"conditional of two literals", "${{ matrix.s == 0 && 'one' || 'two' }}"},
		{"format with a literal template only", "${{ format('bridge ({0}/{1})', matrix.a, matrix.b) }}"},
		{"format with escaped braces", "${{ format('{{x}} {0}', matrix.a) }}"},
	}
	for _, tc := range cannot {
		t.Run("cannot be a required check: "+tc.name, func(t *testing.T) {
			wfText := pfWFHead + pfJobTool + pfJobShel + pfNamed("lint", tc.raw)
			out, rc, _ := pfRun(t, wfText, wfText, docs)
			want := "merge-gate: note: required check shellcheck skipped by path filter (" + wf + " pull_request.paths matches none of the 1 changed files)\n" +
				"merge-gate: note: required check toolbelt-tests skipped by path filter (" + wf + " pull_request.paths matches none of the 1 changed files)\n" +
				allowLine("passive", bound7) + "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
			if out != want || rc != 0 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
			}
		})
	}
	t.Run("a job whose id is the check but whose templated name cannot be it is no carrier", func(t *testing.T) {
		wfText := pfWFHead + pfJobTool + pfNamed("shellcheck", "lint ${{ matrix.n }}")
		out, rc, _ := pfRun(t, wfText, wfText, docs)
		why := "no workflow job named shellcheck in the head tree"
		if !strings.Contains(out, notEval("shellcheck", why)) || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("an expression that can expand to nothing falls back to the job id", func(t *testing.T) {
		sc := pfScanWorkflow(pfWFHead+pfNamed("shellcheck", "${{ '' }}"), "shellcheck")
		if sc.unsup == "" && sc.job {
			t.Fatalf("an empty expansion names the job by its id, so the check could be it: %+v", sc)
		}
	})
	t.Run("a different required check name is judged on its own", func(t *testing.T) {
		wfText := pfWFHead + pfJobTool + pfJobShel + pfNamed("lint", "shell${{ matrix.n }}")
		sc := pfScanWorkflow(wfText, "toolbelt-tests")
		if sc.unsup != "" || !sc.job {
			t.Fatalf("a name that cannot be toolbelt-tests does not void it: %+v", sc)
		}
		sc = pfScanWorkflow(wfText, "shellcheck")
		if sc.unsup != "job name shape of lint" {
			t.Fatalf("a name that can be shellcheck stays unsupported: %+v", sc)
		}
	})
}

// The unreadable job in every position of the jobs list, and alone in its workflow.
func TestPathFilterTemplatedJobNamePosition(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	const wf = wfPath
	skip := func(chk string) string {
		return "merge-gate: note: required check " + chk + " skipped by path filter (" + wf + " pull_request.paths matches none of the 1 changed files)\n"
	}
	allowed := skip("shellcheck") + skip("toolbelt-tests") + allowLine("passive", bound7) +
		"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	why := "cannot parse the jobs of " + wf + " (job name shape of lint, head tree)"
	blocked := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
	cannot := "rsdd-go-bridge (${{ matrix.shard }}/3)"
	could := "${{ matrix.n }}"
	order := func(bad string, pos string) string {
		switch pos {
		case "first":
			return pfWFHead + pfNamed("lint", bad) + pfJobTool + pfJobShel
		case "middle":
			return pfWFHead + pfJobTool + pfNamed("lint", bad) + pfJobShel
		default: // last
			return pfWFHead + pfJobTool + pfJobShel + pfNamed("lint", bad)
		}
	}
	for _, pos := range []string{"first", "middle", "last"} {
		t.Run(pos+": a name that cannot be a required check", func(t *testing.T) {
			wfText := order(cannot, pos)
			out, rc, _ := pfRun(t, wfText, wfText, docs)
			if out != allowed || rc != 0 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, allowed, rc)
			}
		})
		t.Run(pos+": a name that could be a required check", func(t *testing.T) {
			wfText := order(could, pos)
			out, rc, _ := pfRun(t, wfText, wfText, docs)
			if out != blocked || rc != 1 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, blocked, rc)
			}
		})
	}
	t.Run("last line of the file without a trailing newline", func(t *testing.T) {
		wfText := strings.TrimSuffix(order(cannot, "last"), "    runs-on: x\n") + "    runs-on: x"
		out, rc, _ := pfRun(t, wfText, wfText, docs)
		if out != allowed || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		wfText = pfWFHead + pfJobTool + pfJobShel + "  lint:\n    name: " + could
		out, rc, _ = pfRun(t, wfText, wfText, docs)
		if out != blocked || rc != 1 {
			t.Fatalf("name as the very last line: out=%q rc=%d", out, rc)
		}
	})
	t.Run("alone in its workflow file, next to the carriers' workflow", func(t *testing.T) {
		carriers := pfWFHead + pfJobTool + pfJobShel
		alone := func(bad string) func(*scn) {
			return func(sc *scn) {
				for _, tree := range []string{hHead, hPRBase} {
					sc.workflows[tree][".github/workflows/z-alone.yml"] = "name: z\non:\n  pull_request:\njobs:\n" + pfNamed("lint", bad)
				}
			}
		}
		out, rc, _ := pfRun(t, carriers, carriers, docs, alone(cannot))
		if out != allowed || rc != 0 {
			t.Fatalf("out=%q\nwant %q rc=%d", out, allowed, rc)
		}
		out, rc, _ = pfRun(t, carriers, carriers, docs, alone(could))
		why := "cannot parse the jobs of .github/workflows/z-alone.yml (job name shape of lint, head tree)"
		if out != notEval("shellcheck", why)+notEval("toolbelt-tests", why)+missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("alone in the only workflow: nothing carries the checks", func(t *testing.T) {
		wfText := pfWFHead + pfNamed("lint", cannot)
		out, rc, _ := pfRun(t, wfText, wfText, docs)
		why := "no workflow job named "
		if !strings.Contains(out, why+"shellcheck in the head tree") || !strings.Contains(out, why+"toolbelt-tests in the head tree") || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("two unreadable jobs: one that can be the check blocks, one that cannot does not", func(t *testing.T) {
		wfText := pfWFHead + pfJobTool + pfJobShel + pfNamed("a", cannot) + pfNamed("lint", could)
		out, rc, _ := pfRun(t, wfText, wfText, docs)
		if out != blocked || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		wfText = pfWFHead + pfJobTool + pfJobShel + pfNamed("lint", could) + pfNamed("z", cannot)
		out, rc, _ = pfRun(t, wfText, wfText, docs)
		if out != blocked || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}
