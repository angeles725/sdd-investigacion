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
