package gate

import (
	"strings"
	"testing"
)

// End-to-end smoke of RunMerge with the REAL process runner (mergeexec.go: git, gh, gentle-ai as children) against
// real git repositories and the stub gentle-ai/gh of testdata/merge/stubs. The unit tests drive runMerge with a
// scripted runner and the differential (mergediff_test.go) compares with the bash original; this file pins what
// only the real runner does: probing PATH, starting children with the caller's environment, mapping exit codes,
// the bounded gh step and its timeout, and the stub call log. It carries no build tag so it also runs under
// `-tags nodiff` (gremlins), where it is what covers the runner.

func TestRealRunnerEndToEnd(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("starts real processes")
	}
	w := newWorld(t)
	w.buildRepos()
	pass := w.assessFile("false", "passive")
	due := w.assessFile("true", "high_risk")
	green := w.file(runsJSON("shellcheck:completed:success", "toolbelt-tests:completed:success") + "\n")
	files := w.file(ceTests + "\n")
	gql := w.file(gql("true", "MERGED", hMerge, 1, "o/r#41") + "\n")
	plain := []string{"--cwd", "{R}", "--base-ref", "base"}
	mergeArgs := append(append([]string(nil), plain...), "--merge", "7")
	base := []string{"STUB_PR_HEAD={HEAD}", "STUB_PR_BASE={PRB}", "STUB_MERGE_RC=0"}
	env := func(more ...string) []string { return append(append([]string(nil), base...), more...) }

	cases := []struct {
		name     string
		sc       dsc
		rc       int
		out      []string // substrings of stdout
		logHas   []string // substrings of the stub call log
		logHasNo []string
	}{
		{"range-only allow", dsc{repo: "repo", args: plain, env: env("STUB_JSON=" + pass)}, 0,
			[]string{"merge-gate: allow: passive (head=", "range-only; not bound to a PR"}, []string{"review assess --cwd ", "--committed-only --json"}, []string{"pr merge"}},
		{"review due refuses", dsc{repo: "repo", args: plain, env: env("STUB_JSON=" + due)}, 1,
			[]string{"merge-gate: refuse: review_due (high_risk)"}, nil, nil},
		{"assess failure degrades", dsc{repo: "repo", args: plain, env: env("STUB_JSON="+pass, "STUB_RC=2")}, 3,
			[]string{"merge-gate: degraded:"}, nil, nil},
		{"check only binds to the PR", dsc{repo: "repo", args: append(append([]string(nil), plain...), "--pr", "7"), env: env("STUB_JSON=" + pass)}, 0,
			[]string{"bound to PR #7: head equal"}, nil, []string{"pr merge"}},
		{"merge with closure evidence", dsc{repo: "repo", args: mergeArgs, env: env("STUB_JSON="+pass, "STUB_CHECKS_JSON="+green, "STUB_FILES_JSON="+files, "STUB_GQL_JSON="+gql)}, 0,
			[]string{"merge-gate: merged: PR #7 (head=", "closure-evidence: posted: issue #41"},
			[]string{"pr merge 7 --squash --match-head-commit ", "issue comment 41 --repo o/r --body "}, nil},
		{"merge refused by a red check", dsc{repo: "repo", args: mergeArgs, env: env("STUB_JSON="+pass, "STUB_CHECKS_JSON="+w.file(runsJSON("shellcheck:completed:failure", "toolbelt-tests:completed:success")+"\n"))}, 1,
			[]string{"merge-gate: refuse: ci_failed (shellcheck)"}, nil, []string{"pr merge"}},
		{"merge failure degrades", dsc{repo: "repo", args: append(append([]string(nil), mergeArgs...), "--no-closure-evidence"), env: env("STUB_JSON="+pass, "STUB_CHECKS_JSON="+green, "STUB_MERGE_RC=1", "STUB_MERGE_ERR=X Pull request is not mergeable")}, 3,
			[]string{"merge-gate: degraded:", "not mergeable"}, nil, nil},
		{"closure GraphQL timeout is bounded", dsc{repo: "repo", args: mergeArgs, env: env("STUB_JSON="+pass, "STUB_CHECKS_JSON="+green, "STUB_FILES_JSON="+files, "STUB_GQL_JSON="+gql, "STUB_GQL_SLEEP=6", "MERGE_GATE_GH_TIMEOUT=1")}, 0,
			[]string{"merge-gate: merged: PR #7", "closure-evidence: degraded: GraphQL read of PR #7 timed out"}, nil, nil},
		{"closure repo from gh repo view", dsc{repo: "repo", args: mergeArgs, env: env("STUB_JSON="+pass, "STUB_CHECKS_JSON="+green, "STUB_FILES_JSON="+files, "STUB_GQL_JSON="+gql, "STUB_REPO_VIEW_RC=1")}, 0,
			[]string{"closure-evidence: degraded: cannot resolve the repository the merge used (gh repo view:"}, nil, nil},
		{"missing jq", dsc{repo: "repo", args: plain, env: env("STUB_JSON=" + pass), path: "nojq"}, 3,
			[]string{"merge-gate: degraded:", "jq"}, nil, nil},
		{"missing gentle-ai", dsc{repo: "repo", args: plain, env: env("STUB_JSON=" + pass), path: "nogentle"}, 3,
			[]string{"merge-gate: degraded:", "gentle-ai"}, nil, nil},
		{"missing git", dsc{repo: "repo", args: plain, env: env("STUB_JSON=" + pass), path: "nogit"}, 3,
			[]string{"merge-gate: degraded:", "git"}, nil, nil},
		{"missing gh for --pr", dsc{repo: "repo", args: append(append([]string(nil), plain...), "--pr", "7"), env: env("STUB_JSON=" + pass), path: "nogh"}, 3,
			[]string{"merge-gate: degraded:", "gh"}, nil, nil},
		{"not a repository", dsc{repo: "repo", args: []string{"--cwd", "{ROOT}/nowhere", "--base-ref", "base"}, env: env("STUB_JSON=" + pass)}, 3,
			[]string{"merge-gate: degraded:"}, nil, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w.t = t
			r := w.runGo(c.sc)
			if r.rc != c.rc {
				t.Fatalf("rc = %d, want %d\nout=%q\nerr=%q", r.rc, c.rc, r.out, r.err)
			}
			for _, s := range c.out {
				if !strings.Contains(r.out, s) {
					t.Errorf("stdout lacks %q\nout=%q\nerr=%q", s, r.out, r.err)
				}
			}
			for _, s := range c.logHas {
				if !strings.Contains(r.log, s) {
					t.Errorf("stub log lacks %q\nlog=%q", s, r.log)
				}
			}
			for _, s := range c.logHasNo {
				if strings.Contains(r.log, s) {
					t.Errorf("stub log has %q\nlog=%q", s, r.log)
				}
			}
		})
	}
}
