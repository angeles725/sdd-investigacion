package gate

import (
	"strings"
	"testing"
)

// Teeth. The bash suite tests/merge-gate.test.sh built one mutant per guard by editing the text of the old
// script; the script is a shim now, so each guard is pinned here (the frozen original and the differential
// test are in mergediff_test.go). The rows below name the test that fails when the guard is removed:
//
//	usage / argument grammar                     TestUsage
//	probes (git, jq, gentle-ai, gh)               TestProbesInOrder
//	repository questions (git repo, HEAD, base)   TestRepositoryDegrades
//	--head, merge-base, empty range               TestHeadAndRange
//	assess verdicts and schema                    TestAssessVerdicts, TestAssessFailure, TestAssessStream
//	PR binding (head, base, narrow base)          TestPRBinding
//	merge call and its failures                   TestMerge, TestMergeFailure
//	CI gate                                       TestCIGate*, TestCIVerdict, TestCINormalize
//	path filters                                  TestPathFilter*, TestScanWorkflow
//	closure evidence                              TestClosure*

const usageErr = mergeUsageLine + "\n"

func TestUsage(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"--pr without value", []string{"--cwd", "/r", "--base-ref", "m", "--pr"}, "--pr needs a PR number"},
		{"--cwd without value", []string{"--cwd"}, "--cwd needs a value"},
		{"--base-ref without value", []string{"--base-ref"}, "--base-ref needs a value"},
		{"--head without value", []string{"--head"}, "--head needs a value"},
		{"--merge without value", []string{"--merge"}, "--merge needs a PR number"},
		{"--required-checks without value", []string{"--required-checks"}, `--required-checks needs a value (use "" to opt out)`},
		{"unknown flag", mgArgs("--bogus"), "unknown argument: --bogus"},
		{"cwd required", []string{"--base-ref", "main"}, "--cwd is required"},
		{"base-ref required", []string{"--cwd", "/repo"}, "--base-ref is required"},
		{"non-numeric --pr", mgArgs("--pr", "abc"), "--pr/--merge needs a numeric PR number, got: abc"},
		{"non-numeric --merge", mgArgs("--merge", "7x"), "--pr/--merge needs a numeric PR number, got: 7x"},
		{"empty flags count as missing cwd", []string{"--cwd", "", "--base-ref", "main"}, "--cwd is required"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			out, errOut, rc := sc.run(tc.args...)
			if out != "merge-gate: usage: "+tc.want+"\n" || errOut != usageErr || rc != 2 {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
			if len(sc.calls) != 0 {
				t.Fatalf("a usage error must not start any process: %v", sc.calls)
			}
		})
	}
}

func TestArgumentGrammar(t *testing.T) {
	t.Run("a value flag takes the next word whatever it looks like", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run("--cwd", "--base-ref", "--base-ref", "main")
		if rc != 0 || !strings.Contains(out, "base=main") || !sc.called("git rev-parse --verify --quiet main^{commit}") {
			t.Fatalf("out=%q rc=%d calls=%v", out, rc, sc.calls)
		}
	})
	t.Run("the last occurrence wins", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run("--cwd", "/a", "--cwd", "/repo", "--base-ref", "x", "--base-ref", "main")
		if rc != 0 || !strings.Contains(out, "base=main") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("--pr after --merge keeps the merge flag", func(t *testing.T) {
		sc := newScn(t)
		sc.run(mgArgs("--merge", "7", "--pr", "8")...)
		if !sc.called("gh pr merge 8 ") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
	t.Run("an empty --pr is no PR", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run(mgArgs("--pr", "")...)
		if rc != 0 || !strings.Contains(out, "(range-only; not bound to a PR") || sc.called("gh ") {
			t.Fatalf("out=%q rc=%d calls=%v", out, rc, sc.calls)
		}
	})
}

func TestProbesInOrder(t *testing.T) {
	cases := []struct {
		missing []string
		args    []string
		want    string
	}{
		{[]string{"git"}, mgArgs(), "git not found on PATH"},
		{[]string{"jq"}, mgArgs(), "jq not found on PATH"},
		{[]string{"gentle-ai"}, mgArgs(), "gentle-ai not found on PATH"},
		{[]string{"gh"}, mgArgs("--pr", "7"), "gh not found on PATH (needed for --pr/--merge)"},
		{[]string{"gh"}, mgArgs("--merge", "7"), "gh not found on PATH (needed for --pr/--merge)"},
		{[]string{"git", "jq", "gentle-ai", "gh"}, mgArgs("--pr", "7"), "git not found on PATH"},
		{[]string{"jq", "gentle-ai", "gh"}, mgArgs("--pr", "7"), "jq not found on PATH"},
		{[]string{"gentle-ai", "gh"}, mgArgs("--pr", "7"), "gentle-ai not found on PATH"},
	}
	for _, tc := range cases {
		t.Run(strings.Join(tc.missing, ","), func(t *testing.T) {
			sc := newScn(t)
			for _, m := range tc.missing {
				sc.missing[m] = true
			}
			out, errOut, rc := sc.run(tc.args...)
			if out != "merge-gate: degraded: "+tc.want+"\n" || errOut != "DEGRADED: "+tc.want+"\n" || rc != 3 {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
			if len(sc.calls) != 0 {
				t.Fatalf("a probe failure must come before any process: %v", sc.calls)
			}
		})
	}
	t.Run("a run without a PR never needs gh", func(t *testing.T) {
		sc := newScn(t)
		sc.missing["gh"] = true
		if _, _, rc := sc.run(mgArgs()...); rc != 0 {
			t.Fatalf("rc=%d", rc)
		}
	})
}

func TestRepositoryDegrades(t *testing.T) {
	cases := []struct {
		name string
		key  string
		ans  mgCmd
		want string
	}{
		{"cwd is not a repo", "rev-parse --git-dir", failWith(128, "fatal"), "--cwd is not a git repo/worktree: /repo"},
		{"unborn HEAD", "rev-parse --verify HEAD", failWith(128, "fatal"), "cannot resolve HEAD in /repo"},
		{"base-ref unresolvable", "rev-parse --verify --quiet main^{commit}", failWith(1, ""), "base-ref does not resolve to a commit: main"},
		{"no common ancestor", "merge-base HEAD main", failWith(1, ""), "no common ancestor between HEAD and base-ref: main"},
		{"empty merge-base", "merge-base HEAD main", okOut("\n"), "no common ancestor between HEAD and base-ref: main"},
		{"count fails", "rev-list --count " + hBase + "..HEAD", failWith(128, ""), "cannot count commits in " + hBase + "..HEAD"},
		{"count is not a number", "rev-list --count " + hBase + "..HEAD", okOut("x\n"), "cannot count commits in " + hBase + "..HEAD"},
		{"count is empty", "rev-list --count " + hBase + "..HEAD", okOut(""), "cannot count commits in " + hBase + "..HEAD"},
		{"empty range", "rev-list --count " + hBase + "..HEAD", okOut("0\n"), "empty range (nothing to merge): " + hBase + "..HEAD has 0 commits"},
		{"empty range with zeros", "rev-list --count " + hBase + "..HEAD", okOut("00\n"), "empty range (nothing to merge): " + hBase + "..HEAD has 0 commits"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.gitAns[tc.key] = tc.ans
			out, errOut, rc := sc.run(mgArgs()...)
			if out != "merge-gate: degraded: "+tc.want+"\n" || errOut != "DEGRADED: "+tc.want+"\n" || rc != 3 {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
			if sc.called("gentle-ai") {
				t.Fatal("assess must not run after a repository degrade")
			}
		})
	}
	t.Run("two commits ahead is a range", func(t *testing.T) {
		sc := newScn(t)
		sc.gitAns["rev-list --count "+hBase+"..HEAD"] = okOut("2\n")
		if _, _, rc := sc.run(mgArgs()...); rc != 0 {
			t.Fatalf("rc=%d", rc)
		}
	})
}

func TestHeadAndRange(t *testing.T) {
	t.Run("matching --head allows", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run(mgArgs("--head", "abc")...)
		if rc != 0 || !strings.HasPrefix(out, "merge-gate: allow: passive") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		if !sc.called("git rev-parse --verify --quiet abc^{commit}") {
			t.Fatal("--head is resolved to a commit")
		}
	})
	t.Run("mismatching --head refuses", func(t *testing.T) {
		sc := newScn(t)
		sc.gitAns["rev-parse --verify --quiet abc^{commit}"] = okOut(hBase + "\n")
		out, errOut, rc := sc.run(mgArgs("--head", "abc")...)
		want := "merge-gate: refuse: head_mismatch (--head " + hBase + " != worktree HEAD " + hHead + ")\n"
		if out != want || errOut != "" || rc != 1 {
			t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
		}
		if sc.called("gentle-ai") {
			t.Fatal("a head mismatch must refuse before the assess")
		}
	})
	t.Run("unresolvable --head degrades", func(t *testing.T) {
		sc := newScn(t)
		sc.gitAns["rev-parse --verify --quiet abc^{commit}"] = failWith(1, "")
		out, _, rc := sc.run(mgArgs("--head", "abc")...)
		if out != "merge-gate: degraded: --head does not resolve to a commit: abc\n" || rc != 3 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("assess starts at the merge-base, never the moving ref", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run(mgArgs()...)
		want := "merge-gate: allow: passive (head=" + hHead + " base=main merge_base=" + hBase + ") (range-only; not bound to a PR — use --pr N or --merge N)\n"
		if out != want || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		wantCall := "gentle-ai review assess --cwd /repo --base-ref " + hBase + " --committed-only --json"
		if !sc.called(wantCall) || sc.called("gentle-ai review start") || sc.called("gh ") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
}

func TestAssessVerdicts(t *testing.T) {
	const tail = " (head=" + hHead + " base=main merge_base=" + hBase + ")"
	cases := []struct {
		name   string
		json   string
		want   string
		rc     int
		stderr string
	}{
		{"allow already_reviewed", assessJSON("false", "already_reviewed"), "allow: already_reviewed" + tail + " (range-only; not bound to a PR — use --pr N or --merge N)", 0, ""},
		{"allow under_budget", assessJSON("false", "under_budget"), "allow: under_budget" + tail + " (range-only; not bound to a PR — use --pr N or --merge N)", 0, ""},
		{"refuse high_risk", assessJSON("true", "high_risk"), "refuse: review_due (high_risk)" + tail + " — review this exact head before merging", 1, ""},
		{"refuse slice_budget_reached", assessJSON("true", "slice_budget_reached"), "refuse: review_due (slice_budget_reached)" + tail + " — review this exact head before merging", 1, ""},
		{"unknown not-due reason", assessJSON("false", "something_new"), "degraded: unknown not-due reason from gentle-ai: something_new (refusing to guess)", 3, "DEGRADED: unknown not-due reason from gentle-ai: something_new (refusing to guess)\n"},
		{"due with any reason refuses", assessJSON("true", "passive"), "refuse: review_due (passive)" + tail + " — review this exact head before merging", 1, ""},
		{"malformed", "{not json\n", "degraded: assess output is unparseable JSON", 3, "DEGRADED: assess output is unparseable JSON\n"},
		{"empty", "", "degraded: assess output is unparseable JSON", 3, "DEGRADED: assess output is unparseable JSON\n"},
		{"null", "null\n", "degraded: assess output is unparseable JSON", 3, "DEGRADED: assess output is unparseable JSON\n"},
		{"false", "false\n", "degraded: assess output is unparseable JSON", 3, "DEGRADED: assess output is unparseable JSON\n"},
		{"wrong schema", `{"schema":"other/v9","review_due":false,"review_due_reason":"passive"}`, "degraded: unexpected assess schema: other/v9", 3, "DEGRADED: unexpected assess schema: other/v9\n"},
		{"no schema", `{"review_due":false,"review_due_reason":"passive"}`, "degraded: unexpected assess schema: <none>", 3, "DEGRADED: unexpected assess schema: <none>\n"},
		{"non-boolean review_due", `{"schema":"gentle-ai.review-assessment/v1","review_due":"no","review_due_reason":"passive"}`, "degraded: assess review_due is missing or not a boolean", 3, "DEGRADED: assess review_due is missing or not a boolean\n"},
		{"missing review_due", `{"schema":"gentle-ai.review-assessment/v1","review_due_reason":"passive"}`, "degraded: assess review_due is missing or not a boolean", 3, "DEGRADED: assess review_due is missing or not a boolean\n"},
		{"missing reason", `{"schema":"gentle-ai.review-assessment/v1","review_due":false}`, "degraded: assess review_due_reason is missing", 3, "DEGRADED: assess review_due_reason is missing\n"},
		{"null reason", `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":null}`, "degraded: assess review_due_reason is missing", 3, "DEGRADED: assess review_due_reason is missing\n"},
		{"false reason", `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":false}`, "degraded: assess review_due_reason is missing", 3, "DEGRADED: assess review_due_reason is missing\n"},
		{"not an object", `[1]`, "degraded: unexpected assess schema: <none>", 3, "DEGRADED: unexpected assess schema: <none>\n"},
		{"trailing newline in the reason is stripped like $(...)", `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":"passive\n"}`, "allow: passive" + tail + " (range-only; not bound to a PR — use --pr N or --merge N)", 0, ""},
		{"numeric reason is printed as written", `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":5}`, "refuse: review_due (5)" + tail + " — review this exact head before merging", 1, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.assess = okOut(tc.json)
			out, errOut, rc := sc.run(mgArgs()...)
			if out != "merge-gate: "+tc.want+"\n" || errOut != tc.stderr || rc != tc.rc {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
		})
	}
}

func TestAssessStream(t *testing.T) {
	// jq reads every value of the stream: an extra object with another shape makes the captured text differ.
	good := `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":"passive"}`
	cases := []struct {
		name, json, want string
		rc               int
	}{
		{"two identical objects: the schema is two lines", good + good, "degraded: unexpected assess schema: gentle-ai.review-assessment/v1\ngentle-ai.review-assessment/v1", 3},
		{"a trailing value that is not an object is skipped", good + " 5", "allow: passive", 0},
		{"a leading null is skipped but reads as review_due invalid", "null " + good, "degraded: assess review_due is missing or not a boolean", 3},
		{"garbage after the object", good + " garbage", "degraded: assess output is unparseable JSON", 3},
		{"a trailing null makes jq -e fail", good + " null", "degraded: assess output is unparseable JSON", 3},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.assess = okOut(tc.json)
			out, _, rc := sc.run(mgArgs()...)
			if !strings.HasPrefix(out, "merge-gate: "+tc.want) || rc != tc.rc {
				t.Fatalf("out=%q rc=%d", out, rc)
			}
		})
	}
}

func TestAssessFailure(t *testing.T) {
	cases := []struct {
		name   string
		cmd    mgCmd
		want   string
		stderr string
	}{
		{"non-zero exit even with allow-shaped output", mgCmd{Stdout: []byte(assessJSON("false", "passive")), RC: 1}, "gentle-ai review assess failed (exit 1)", ""},
		{"own first error line", mgCmd{RC: 1, Stderr: []byte("Error: boom\nsecond line\n")}, "gentle-ai review assess failed (exit 1): Error: boom", ""},
		{"untracked hint", mgCmd{RC: 2, Stderr: []byte("Error: untracked files require an explicit declaration\n")}, "gentle-ai review assess failed (exit 2): Error: untracked files require an explicit declaration — clean or ignore untracked files in /repo and retry", ""},
		{"untracked hint is case-insensitive and reads every line", mgCmd{RC: 1, Stderr: []byte("first\nUNTRACKED later\n")}, "gentle-ai review assess failed (exit 1): first — clean or ignore untracked files in /repo and retry", ""},
		{"no hint on unrelated errors", mgCmd{RC: 1, Stderr: []byte("Error: something else\n")}, "gentle-ai review assess failed (exit 1): Error: something else", ""},
		{"line is cut to 200 bytes", mgCmd{RC: 1, Stderr: []byte(strings.Repeat("x", 250) + "\n")}, "gentle-ai review assess failed (exit 1): " + strings.Repeat("x", 200), ""},
		{"timeout code", mgCmd{RC: 124, Timeout: true}, "gentle-ai review assess failed (exit 124)", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.assess = tc.cmd
			out, errOut, rc := sc.run(mgArgs()...)
			if out != "merge-gate: degraded: "+tc.want+"\n" || errOut != "DEGRADED: "+tc.want+"\n" || rc != 3 {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
		})
	}
	t.Run("HEAD moving during the assess is degraded", func(t *testing.T) {
		sc := newScn(t)
		sc.moveHead = hBase
		out, _, rc := sc.run(mgArgs()...)
		want := "merge-gate: degraded: HEAD moved during assess (" + hHead + " -> " + hBase + "); rerun\n"
		if out != want || rc != 3 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("HEAD unreadable after the assess is unknown", func(t *testing.T) {
		sc := newScn(t)
		sc.headAfterFail = true
		out, _, rc := sc.run(mgArgs()...)
		if out != "merge-gate: degraded: HEAD moved during assess ("+hHead+" -> unknown); rerun\n" || rc != 3 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}
