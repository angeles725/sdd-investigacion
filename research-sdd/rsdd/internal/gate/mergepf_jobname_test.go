package gate

import (
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"
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

// Kit issue #2852 (verifier round): the reader does not decode YAML scalars, so a templated name: it cannot read as a
// plain one-line scalar without escapes is "could be anything" (fail-closed), because GitHub decodes the scalar first
// (quote doubling, double-quoted escapes, line folding) and only then expands the expression. Each case below is a
// name GitHub expands to exactly a required check (or to a spelling of it a lenient comparison would equate).
const (
	wfZB    = ".github/workflows/z-b.yml"
	pfOKJob = "  ok:\n    runs-on: x\n"
)

// pfZB adds a second workflow, on: pull_request with no path filter, whose jobs are job, to both trees.
func pfZB(job string) func(*scn) {
	return func(sc *scn) {
		for _, tree := range []string{hHead, hPRBase} {
			sc.workflows[tree][wfZB] = "name: z\non: pull_request\njobs:\n" + job
		}
	}
}

func TestPathFilterJobNameScalarShapeIsFailClosed(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
	blocked := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
	named := func(raw string) string { return pfNamed("lint", raw) }
	cases := []struct {
		name, job string
		fixed     bool // run only as written (the position is the point)
	}{
		{"1 single-quoted scalar: doubled quote decodes to one quote", named(`'${{ '''' }}shellcheck'`), false},
		{"1b single-quoted scalar with a lone quote inside", named(`'${{ '' }}shellcheck'`), false},
		{"2 double-quoted hex escape", named(`"${{ '' }}shell\x63heck"`), false},
		{"2b double-quoted unicode escape", named(`"${{ '' }}shell\u0063heck"`), false},
		{"2c escape that decodes to the expression opener", named(`"\x24{{ '' }}shellcheck"`), false},
		{"2d escaped quote inside a double-quoted scalar", named(`"${{ '' }}\"shellcheck"`), false},
		{"3 double-quoted scalar continued across lines", "  lint:\n    name: \"shell${{ '' }}\\\n      check\"\n    runs-on: x\n", false},
		{"3b unbalanced opening quote with a continuation line", "  lint:\n    name: \"${{ matrix.n }}\n      x\"\n    runs-on: x\n", false},
		{"3c unbalanced opening quote on one line", named(`"${{ '' }}shellcheck`), false},
		{"3e mismatched outer quotes", named(`"${{ '' }}shellcheck'`), false},
		{"3f trailing backslash in a plain scalar", named(`${{ '' }}shellcheck\`), false},
		{"3g a comment cuts the closing quote off", named(`"${{ '' }}shellcheck # "`), false},
		{"4 plain scalar folded over a deeper-indented line", "  lint:\n    name: ${{ 'rsdd-go-bridge' }}\n      (1/3)\n    runs-on: x\n", false},
		{"4b plain scalar whose continuation follows a comment line", "  lint:\n    name: ${{ '' }}shell\n    # c\n      check\n    runs-on: x\n", false},
		{"4c continuation after a blank line", "  lint:\n    name: ${{ '' }}shell\n\n      check\n    runs-on: x\n", false},
		{"4d continuation is the last line of the file", "  lint:\n    name: ${{ 'rsdd-go-bridge' }}\n      (1/3)", true},
		{"4e continuation is the last line, with a trailing newline", "  lint:\n    name: ${{ 'rsdd-go-bridge' }}\n      (1/3)\n", true},
		{"5 CR at the end of the name line only", named("${{ '' }}shellcheck\r"), false},
		{"5b CR after a literal suffix", named("${{ matrix.n }}check\r"), false},
		{"5c CR after a closing quote", named("\"${{ '' }}shellcheck\"\r"), false},
		{"5d CR on the name line, which is the last line of a file without a trailing newline", "  lint:\n    name: ${{ '' }}shellcheck\r", true},
		{"5e other control character in the value", named("${{ '' }}shell\x01check"), false},
		{"5f tab inside the value", named("${{ '' }}shell\tcheck"), false},
	}
	for _, tc := range cases {
		jobs := []string{tc.job}
		if !tc.fixed {
			jobs = []string{tc.job, tc.job + pfOKJob, pfOKJob + tc.job, pfOKJob + tc.job + pfOKJob, strings.TrimSuffix(tc.job, "\n")}
		}
		for i, job := range jobs {
			t.Run(tc.name+"/variant "+string(rune('a'+i)), func(t *testing.T) {
				out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(job))
				if out != blocked || rc != 1 {
					t.Fatalf("job=%q\nout=%q\nwant %q rc=%d", job, out, blocked, rc)
				}
			})
		}
	}
	t.Run("4f the continuation completes a custom required check", func(t *testing.T) {
		src := pfWFHead + "  lint:\n    name: ${{ 'rsdd-go-bridge' }}\n      (1/3)\n    runs-on: x\n"
		sc := pfScanWorkflow(src, "rsdd-go-bridge (1/3)")
		if sc.unsup != "job name shape of lint" {
			t.Fatalf("a folded name could be the check: %+v", sc)
		}
	})
}

// Names the scalar rule must keep evaluating: readable plain one-line scalars and quoted ones without escapes.
func TestPathFilterJobNameScalarShapeStillEvaluated(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	skip := func(chk string) string {
		return "merge-gate: note: required check " + chk + " skipped by path filter (" + wfPath + " pull_request.paths matches none of the 1 changed files)\n"
	}
	allowed := skip("shellcheck") + skip("toolbelt-tests") + allowLine("passive", bound7) +
		"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	const bridge = "rsdd-go-bridge (${{ matrix.shard }}/3)"
	cases := []struct{ name, job string }{
		{"plain", pfNamed("lint", bridge)},
		{"plain with a trailing comment", pfNamed("lint", bridge+" # bridge")},
		{"single-quoted without quotes inside", pfNamed("lint", "'"+bridge+"'")},
		{"double-quoted with a string literal inside", pfNamed("lint", `"${{ matrix.shard == 0 && 'rsdd-go-bridge' || 'x' }}"`)},
		{"next key at the same indent", "  lint:\n    name: " + bridge + "\n    runs-on: x\n"},
		{"comment line, then the next key", "  lint:\n    name: " + bridge + "\n    # c\n    runs-on: x\n"},
		{"next job right after the name", "  lint:\n    name: " + bridge + "\n" + pfOKJob},
		{"name is the last line, LF", "  lint:\n    name: " + bridge + "\n"},
		{"name is the last line, no trailing newline", "  lint:\n    name: " + bridge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(tc.job))
			if out != allowed || rc != 0 {
				t.Fatalf("job=%q\nout=%q\nwant %q rc=%d", tc.job, out, allowed, rc)
			}
		})
	}
}

// Whitespace and case (GitHub's behaviour was not verified, so each is decided fail-closed).
func TestPathFilterJobNameWhitespaceAndCase(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
	onlyShellcheck := notEval("shellcheck", why) +
		"merge-gate: note: required check toolbelt-tests skipped by path filter (" + wfPath + " pull_request.paths matches none of the 1 changed files)\n" +
		"merge-gate: refuse: ci_missing (shellcheck) (head=" + hHead + ") — CI for this exact head must be green before merging\n"
	skip := func(chk string) string {
		return "merge-gate: note: required check " + chk + " skipped by path filter (" + wfPath + " pull_request.paths matches none of the 1 changed files)\n"
	}
	allowed := skip("shellcheck") + skip("toolbelt-tests") + allowLine("passive", bound7) +
		"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	for _, raw := range []string{
		"${{ 'shellcheck ' }}",
		"${{ ' shellcheck' }}",
		"${{ '\u00a0shellcheck' }}",
		"${{ format('  shell{0}  ', matrix.n) }}",
		"${{ ' ' }}${{ 'shellcheck' }}${{ ' ' }}",
		"${{ matrix.n }} shellcheck",                // the gap may be blank, so the space is trimmed away
		"shellcheck ${{ matrix.n }}",                // likewise at the other end
		"${{ matrix.a }}shellcheck ${{ matrix.b }}", // blank gap at the end only
		"${{ 'ShellCheck' }}",
		"SHELL${{ matrix.n }}",
		"${{ matrix.n }}CHECK",
		"${{ 'ſhellcheck' }}", // U+017F folds to s
		"${{ 'shellchecK' }}",
	} {
		t.Run("could be shellcheck: "+raw, func(t *testing.T) {
			out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(pfNamed("lint", raw)))
			if out != onlyShellcheck || rc != 1 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, onlyShellcheck, rc)
			}
		})
	}
	for _, raw := range []string{
		"shell ${{ matrix.n }}",   // a space inside is not trimmed away
		"${{ ' x ' }}",            // trimmed: still not the check
		"${{ 'shell check' }}",    // inner whitespace stays
		"${{ matrix.n }} check x", // literal text after the gap
	} {
		t.Run("cannot be a required check: "+raw, func(t *testing.T) {
			out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(pfNamed("lint", raw)))
			if out != allowed || rc != 0 {
				t.Fatalf("out=%q\nwant %q rc=%d", out, allowed, rc)
			}
		})
	}
	scan := func(id, raw string) pfScan {
		return pfScanWorkflow(pfWFHead+pfNamed(id, raw), "shellcheck")
	}
	t.Run("a whitespace-only possible expansion may be empty: the job id applies", func(t *testing.T) {
		for _, raw := range []string{"${{ ' ' }}", "${{ '\u00a0' }}", "${{ matrix.s == 0 && ' ' || 'x' }}", "${{ format(' {0} ', matrix.n) }}"} {
			if sc := scan("shellcheck", raw); sc.unsup != "job name shape of shellcheck" {
				t.Errorf("%s: a blank name falls back to the id shellcheck: %+v", raw, sc)
			}
		}
	})
	t.Run("a possible expansion with text does not fall back to the job id", func(t *testing.T) {
		if sc := scan("shellcheck", "${{ ' x ' }}"); sc.unsup != "" || sc.job {
			t.Fatalf("%+v", sc)
		}
	})
	t.Run("the job id comparison ignores case", func(t *testing.T) {
		if sc := scan("ShellCheck", "${{ '' }}"); sc.unsup != "job name shape of ShellCheck" {
			t.Fatalf("%+v", sc)
		}
	})
}

// Kit issue #2852 (second verifier round). The reader looks at one line at a time, so a `name:` line it finds at the
// job-key indent may be no key at all: a quoted scalar or a flow collection opened on an earlier line of the job
// swallows it (GitHub then names the job by its id). The job's templated name cannot be trusted whenever some line of
// the job leaves a quote or bracket open, and a job with two `name:` keys has no single name.
func TestPathFilterJobNameHiddenByAnOpenValue(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
	blocked := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
	// every job below names itself `bridge-${{ matrix.n }}`, which cannot be a required check, on a line that the
	// open value before (or after) it makes no key (or makes one the reader cannot place)
	cases := []struct{ name, job string }{
		{"R1 double-quoted scalar swallows the name line", "  lint:\n    runs-on: \"foo\n    name: bridge-${{ matrix.n }}\"\n"},
		{"R1 single-quoted scalar swallows the name line", "  lint:\n    runs-on: 'foo\n    name: bridge-${{ matrix.n }}'\n"},
		{"R1 flow mapping swallows the name line", "  lint:\n    env: {a: 1,\n    name: bridge-${{ matrix.n }} }\n    runs-on: x\n"},
		{"R1 flow sequence swallows the name line", "  lint:\n    needs: [a,\n    name: bridge-${{ matrix.n }} ]\n    runs-on: x\n"},
		{"R1 open quote on the job key line", "  lint: \"foo\n    name: bridge-${{ matrix.n }}\"\n"},
		{"R1 open value after a sequence dash", "  lint:\n    labels:\n    - \"foo\n    name: bridge-${{ matrix.n }}\"\n"},
		{"R1 stray quote in a plain key before the quote that opens the value", "  lint:\n    it's: \"foo's\n    name: bridge-${{ matrix.n }}\n    done\" # \"\n"},
		{"R1 quote opened after the name line", "  lint:\n    name: bridge-${{ matrix.n }}\n    runs-on: \"foo\n      bar\"\n"},
		{"R1 flow collection opened after the name line", "  lint:\n    name: bridge-${{ matrix.n }}\n    needs: [a,\n      b]\n"},
		{"R1 open value is the last line of the file", "  lint:\n    name: bridge-${{ matrix.n }}\n    runs-on: \"foo"},
		{"R1 quote kept open past a trailing comment", "  lint:\n    runs-on: \"foo # c\n    name: bridge-${{ matrix.n }}\"\n"},
		{"R1 open value deeper in a step list", "  lint:\n    name: bridge-${{ matrix.n }}\n    steps:\n      - run: echo \"a\n          b\"\n"},
	}
	for _, tc := range cases {
		jobs := []string{tc.job, tc.job + pfOKJob, pfOKJob + tc.job, pfOKJob + tc.job + pfOKJob}
		for i, job := range jobs {
			t.Run(tc.name+"/variant "+string(rune('a'+i)), func(t *testing.T) {
				out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(job))
				if out != blocked || rc != 1 {
					t.Fatalf("job=%q\nout=%q\nwant %q rc=%d", job, out, blocked, rc)
				}
			})
		}
	}
	t.Run("through pfScanWorkflow: the typed note names the job", func(t *testing.T) {
		src := pfWFHead + "  shellcheck:\n    runs-on: \"foo\n    name: bridge-${{ matrix.n }}\"\n"
		for _, chk := range []string{"shellcheck", "toolbelt-tests"} {
			if sc := pfScanWorkflow(src, chk); sc.unsup != "job name shape of shellcheck" {
				t.Fatalf("%s: %+v", chk, sc)
			}
		}
	})
}

func TestPathFilterJobNameDuplicateKey(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
	blocked := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
	const tpl = "    name: bridge-${{ matrix.n }}\n"
	cases := []struct{ name, job string }{
		{"R2 plain name, then a templated one", "  lint:\n    name: shellcheck\n" + tpl + "    runs-on: x\n"},
		{"R2 templated name, then a plain one", "  lint:\n" + tpl + "    name: shellcheck\n    runs-on: x\n"},
		{"R2 two templated names that cannot be a check", "  lint:\n" + tpl + "    runs-on: x\n    name: other-${{ matrix.n }}\n"},
		{"R2 duplicate name is the last line of the file", "  lint:\n    name: shellcheck\n" + tpl},
		{"R2 duplicate templated name split by another key", "  lint:\n" + tpl + "    runs-on: x\n    name: lint\n"},
	}
	for _, tc := range cases {
		jobs := []string{tc.job, tc.job + pfOKJob, pfOKJob + tc.job, pfOKJob + tc.job + pfOKJob}
		for i, job := range jobs {
			t.Run(tc.name+"/variant "+string(rune('a'+i)), func(t *testing.T) {
				out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(job))
				if out != blocked || rc != 1 {
					t.Fatalf("job=%q\nout=%q\nwant %q rc=%d", job, out, blocked, rc)
				}
			})
		}
	}
	t.Run("two plain names, none templated: unchanged, the last one names the job", func(t *testing.T) {
		src := pfWFHead + "  lint:\n    name: shellcheck\n    name: other\n"
		if sc := pfScanWorkflow(src, "shellcheck"); sc.unsup != "" || sc.job {
			t.Fatalf("%+v", sc)
		}
	})
}

// A templated name next to values that are long or odd but cannot hide a key stays evaluated: block scalars (their
// content is indented deeper than the key that opens them), balanced quotes and brackets, comments with apostrophes.
func TestPathFilterJobNameNoFalseRefusal(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	skip := func(chk string) string {
		return "merge-gate: note: required check " + chk + " skipped by path filter (" + wfPath + " pull_request.paths matches none of the 1 changed files)\n"
	}
	allowed := skip("shellcheck") + skip("toolbelt-tests") + allowLine("passive", bound7) +
		"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	const nm = "    name: bridge-${{ matrix.n }}\n"
	cases := []struct{ name, job string }{
		{"run block scalar with unbalanced quotes and braces", "  lint:\n" + nm + "    steps:\n      - run: |\n          echo \"a\n          f() {\n          name: x'\n      - run: echo ok\n"},
		{"folded block scalar at the job key indent", "  lint:\n" + nm + "    if: >-\n      a ' b\n    runs-on: x\n"},
		{"block scalar with an indentation indicator and a comment", "  lint:\n" + nm + "    run: |2+ # c\n        \"x\n    runs-on: x\n"},
		{"block scalar in a sequence item", "  lint:\n" + nm + "    steps:\n      - |\n        {\n      - x\n"},
		{"balanced quotes and one-line flow collections", "  lint:\n" + nm + "    env: {a: \"1\", b: 'it''s'}\n    needs: [a, b]\n    runs-on: \"x\"\n"},
		{"quote inside an expression", "  lint:\n" + nm + "    if: ${{ matrix.n == '{' || matrix.n == '[' }}\n"},
		{"apostrophe in a comment", "  lint:\n" + nm + "    runs-on: x # don't \"quote\" {me\n"},
		{"comment lines with open quotes", "  lint:\n    # \"a\n" + nm + "    # {\n    runs-on: x\n"},
		{"open value in ANOTHER job does not taint this one", "  lint:\n" + nm + "    runs-on: x\n  other:\n    runs-on: x\n"},
	}
	for _, tc := range cases {
		jobs := []string{tc.job, tc.job + pfOKJob, pfOKJob + tc.job, pfOKJob + tc.job + pfOKJob}
		for i, job := range jobs {
			t.Run(tc.name+"/variant "+string(rune('a'+i)), func(t *testing.T) {
				out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(job))
				if out != allowed || rc != 0 {
					t.Fatalf("job=%q\nout=%q\nwant %q rc=%d", job, out, allowed, rc)
				}
			})
		}
	}
	t.Run("the real rsdd-go workflow keeps its templated job evaluated", func(t *testing.T) {
		src := wfFixture(t, "wf-real-rsdd-go.yml")
		for _, chk := range []string{"shellcheck", "toolbelt-tests"} {
			if sc := pfScanWorkflow(src, chk); sc.unsup != "" || sc.job {
				t.Fatalf("%s: %+v", chk, sc)
			}
		}
	})
}

// Scope note (differs from the original): a double-quoted name with a backslash voids the evaluation even without
// `${{`, because an escape can spell any character of a check name.
func TestPathFilterJobNameBackslashWithoutExpression(t *testing.T) {
	const docs = `[{"status":"added","filename":"docs/yy.md"}]`
	carriers := pfWFHead + pfJobTool + pfJobShel
	why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
	blocked := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
	for _, raw := range []string{`"shell\x63heck"`, `"x\u0063"`, `"a\"b"`} {
		for i, job := range []string{pfNamed("lint", raw), pfNamed("lint", raw) + pfOKJob, pfOKJob + pfNamed("lint", raw)} {
			t.Run(raw+"/variant "+string(rune('a'+i)), func(t *testing.T) {
				out, rc, _ := pfRun(t, carriers, carriers, docs, pfZB(job))
				if out != blocked || rc != 1 {
					t.Fatalf("out=%q\nwant %q rc=%d", out, blocked, rc)
				}
			})
		}
	}
	t.Run("a single-quoted plain name with a backslash is a literal and stays evaluated", func(t *testing.T) {
		if sc := pfScanWorkflow(pfWFHead+pfNamed("lint", `'a\b'`), "shellcheck"); sc.unsup != "" || sc.job {
			t.Fatalf("%+v", sc)
		}
	})
}

// Kit issue #2852 (second verifier round): pfTrimAlts (now pfEachTrimmed) recursed from both ends and was exponential in the number of
// blank-capable parts (24 expressions took 10 s, 28 never returned). The gate must answer in milliseconds.
func TestPathFilterJobNameManyExpressionsAnswersFast(t *testing.T) {
	const expr = "${{ matrix.a }}"
	within := func(t *testing.T, name string, f func()) {
		t.Helper()
		done := make(chan struct{})
		start := time.Now()
		go func() { f(); close(done) }()
		select {
		case <-done:
			if d := time.Since(start); d > time.Second {
				t.Fatalf("%s: answered in %v, want milliseconds", name, d)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: no answer within 2s (exponential enumeration)", name)
		}
	}
	for _, n := range []int{24, 28, 40, 200, 2000} {
		t.Run("expressions="+strconv.Itoa(n), func(t *testing.T) {
			many := strings.Repeat(expr, n)
			var anyCheck, other pfScan
			within(t, "unknown name", func() {
				anyCheck = pfScanWorkflow(pfWFHead+pfNamed("lint", many), "shellcheck")
				other = pfScanWorkflow(pfWFHead+pfNamed("lint", "bridge-"+many), "shellcheck")
			})
			if anyCheck.unsup != "job name shape of lint" {
				t.Fatalf("a name made only of unknown expressions could be anything: %+v", anyCheck)
			}
			if n+1 > 32 { // pfMaxParts (pinned here so raising the cap is a visible test change)
				// too many parts to enumerate: fail closed even though the literal prefix cannot fit
				if other.unsup != "job name shape of lint" {
					t.Fatalf("above the cap the name counts as possibly anything: %+v", other)
				}
			} else if other.unsup != "" {
				t.Fatalf("`bridge-` cannot start a required check: %+v", other)
			}
		})
	}
	t.Run("end to end with 200 expressions", func(t *testing.T) {
		const docs = `[{"status":"added","filename":"docs/yy.md"}]`
		carriers := pfWFHead + pfJobTool + pfJobShel
		why := "cannot parse the jobs of " + wfZB + " (job name shape of lint, head tree)"
		want := notEval("shellcheck", why) + notEval("toolbelt-tests", why) + missingCI
		var out string
		var rc int
		within(t, "pfRun", func() {
			out, rc, _ = pfRun(t, carriers, carriers, docs, pfZB(pfNamed("lint", strings.Repeat("${{ matrix.a }}", 200))))
		})
		if out != want || rc != 1 {
			t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
		}
	})
	t.Run("blank-capable parts at both ends still trim away", func(t *testing.T) {
		// 30 unknown gaps around `shellcheck `: some reading is exactly shellcheck
		src := pfWFHead + pfNamed("lint", strings.Repeat("${{ matrix.a }}", 30)+"shellcheck ")
		if sc := pfScanWorkflow(src, "shellcheck"); sc.unsup != "job name shape of lint" {
			t.Fatalf("%+v", sc)
		}
	})
}

// pfTrimAltsReference is the previous recursive enumeration (exponential, kept only as the oracle): every reading is
// the parts with the leading whitespace of the first and the trailing whitespace of the last removed, for every way of
// dropping blank edge parts.
func pfTrimAltsReference(a pfAlt) []pfAlt {
	parts := make([]string, len(a.parts))
	for i, p := range a.parts {
		parts[i] = pfFold(p)
	}
	var out []pfAlt
	var walk func(parts []string)
	walk = func(parts []string) {
		t := append([]string{}, parts...)
		t[0] = strings.TrimLeftFunc(t[0], unicode.IsSpace)
		t[len(t)-1] = strings.TrimRightFunc(t[len(t)-1], unicode.IsSpace)
		out = append(out, pfAlt{parts: t, truthy: a.truthy, falsy: a.falsy})
		if len(parts) > 1 && strings.TrimSpace(parts[0]) == "" {
			walk(parts[1:])
		}
		if len(parts) > 1 && strings.TrimSpace(parts[len(parts)-1]) == "" {
			walk(parts[:len(parts)-1])
		}
	}
	walk(parts)
	return out
}

func TestPfTrimReadingsMatchTheRecursiveReference(t *testing.T) {
	alphabet := []string{"", " ", "a", " a ", "\u00a0", "B"}
	key := func(a pfAlt) string { return strings.Join(a.parts, "\x00") }
	set := func(alts []pfAlt) []string {
		seen := map[string]bool{}
		for _, a := range alts {
			seen[key(a)] = true
		}
		var out []string
		for k := range seen {
			out = append(out, k)
		}
		sort.Strings(out)
		return out
	}
	var gen func(prefix []string, n int)
	checked := 0
	gen = func(prefix []string, n int) {
		if len(prefix) == n {
			a := pfAlt{parts: append([]string{}, prefix...), truthy: true}
			var got []pfAlt
			pfEachTrimmed(a, func(r pfAlt) bool {
				got = append(got, pfAlt{parts: append([]string{}, r.parts...), truthy: r.truthy, falsy: r.falsy})
				return false
			})
			g, w := set(got), set(pfTrimAltsReference(a))
			if strings.Join(g, "|") != strings.Join(w, "|") {
				t.Fatalf("parts=%q\n got %q\nwant %q", a.parts, g, w)
			}
			checked++
			return
		}
		for _, p := range alphabet {
			gen(append(prefix, p), n)
		}
	}
	for n := 1; n <= 5; n++ {
		gen(nil, n)
	}
	if checked < 7000 {
		t.Fatalf("only %d part lists compared", checked)
	}
	t.Run("the callback stops the enumeration", func(t *testing.T) {
		calls := 0
		a := pfAlt{parts: []string{"", "", "", ""}}
		if !pfEachTrimmed(a, func(pfAlt) bool { calls++; return true }) || calls != 1 {
			t.Fatalf("calls=%d", calls)
		}
	})
}
