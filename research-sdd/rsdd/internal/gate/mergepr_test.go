package gate

import (
	"strings"
	"testing"
)

const bound7 = "(bound to PR #7: head equal, range starts at or before the PR branch point)"

func allowLine(reason, tail string) string {
	return "merge-gate: allow: " + reason + " (head=" + hHead + " base=main merge_base=" + hBase + ") " + tail + "\n"
}

func TestPRBinding(t *testing.T) {
	prAPI := "api repos/{owner}/{repo}/pulls/7"
	t.Run("--pr binds, reads the PR over REST and never merges", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run(mgArgs("--pr", "7")...)
		if out != allowLine("passive", bound7) || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		want := "gh api repos/{owner}/{repo}/pulls/7 --jq {headRefOid:.head.sha, baseRefOid:.base.sha, baseRefName:.base.ref}"
		if !sc.called(want) || sc.called("gh pr merge") || sc.called("gh pr view") || sc.called("ghb") {
			t.Fatalf("calls=%v", sc.calls)
		}
		if !sc.called("git merge-base --is-ancestor "+hBase+" "+hBase) || !sc.called("git cat-file -e "+hPRBase+"^{commit}") {
			t.Fatalf("the range is checked against the PR base: %v", sc.calls)
		}
	})
	t.Run("PR head differs from HEAD", func(t *testing.T) {
		sc := newScn(t)
		sc.prHead = hBase
		out, errOut, rc := sc.run(mgArgs("--pr", "7")...)
		want := "merge-gate: refuse: head_mismatch (PR #7 head " + hBase + " != checked HEAD " + hHead + ")\n"
		if out != want || errOut != "" || rc != 1 {
			t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
		}
		if sc.called("gentle-ai") {
			t.Fatal("refuse before the assess")
		}
	})
	degraded := []struct {
		name string
		set  func(sc *scn)
		want string
	}{
		{"gh api fails", func(sc *scn) { sc.ghAns[prAPI] = failWith(1, "boom") }, "cannot read PR #7 (gh api failed)"},
		{"gh api prints nothing", func(sc *scn) { sc.ghAns[prAPI] = okOut("") }, "cannot read PR #7 (gh api failed)"},
		{"gh api output is only newlines", func(sc *scn) { sc.ghAns[prAPI] = okOut("\n\n") }, "cannot read PR #7 (gh api failed)"},
		{"no headRefOid", func(sc *scn) { sc.ghAns[prAPI] = okOut(`{"baseRefOid":"` + hPRBase + `"}`) }, "cannot read PR #7 head (no headRefOid)"},
		{"null headRefOid", func(sc *scn) { sc.ghAns[prAPI] = okOut(`{"headRefOid":null,"baseRefOid":"x"}`) }, "cannot read PR #7 head (no headRefOid)"},
		{"unparseable answer", func(sc *scn) { sc.ghAns[prAPI] = okOut(`{nope`) }, "cannot read PR #7 head (no headRefOid)"},
		{"no baseRefOid", func(sc *scn) { sc.ghAns[prAPI] = okOut(`{"headRefOid":"` + hHead + `"}`) }, "cannot read PR #7 base (no baseRefOid)"},
		{"base commit absent locally", func(sc *scn) { sc.gitAns["cat-file -e "+hPRBase+"^{commit}"] = failWith(128, "") }, "PR #7 base " + hPRBase + " is not present locally (git fetch first)"},
		{"no common ancestor with the PR base", func(sc *scn) { sc.gitAns["merge-base HEAD "+hPRBase] = failWith(1, "") }, "no common ancestor between HEAD and PR #7 base"},
	}
	for _, tc := range degraded {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			tc.set(sc)
			out, errOut, rc := sc.run(mgArgs("--pr", "7")...)
			if out != "merge-gate: degraded: "+tc.want+"\n" || errOut != "DEGRADED: "+tc.want+"\n" || rc != 3 {
				t.Fatalf("out=%q err=%q rc=%d", out, errOut, rc)
			}
			if sc.called("gentle-ai") {
				t.Fatal("degraded before the assess")
			}
		})
	}
	t.Run("a narrow --base-ref cannot hide earlier PR commits", func(t *testing.T) {
		sc := newScn(t)
		const prMB = "4444444444444444444444444444444444444444"
		sc.gitAns["merge-base HEAD "+hPRBase] = okOut(prMB + "\n")
		sc.gitAns["merge-base --is-ancestor "+hBase+" "+prMB] = failWith(1, "")
		for _, flag := range []string{"--pr", "--merge"} {
			out, _, rc := sc.run(mgArgs(flag, "7")...)
			want := "merge-gate: refuse: base_excludes_pr_commits (assessed range starts at " + hBase + ", after the PR branch point " + prMB + ") — use the PR base as --base-ref\n"
			if out != want || rc != 1 {
				t.Fatalf("%s: out=%q rc=%d", flag, out, rc)
			}
		}
		if sc.called("gh pr merge") || sc.called("gentle-ai") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
	t.Run("without a PR the narrow base stays a pure check", func(t *testing.T) {
		sc := newScn(t)
		sc.gitAns["merge-base --is-ancestor "+hBase+" x"] = failWith(1, "")
		out, _, rc := sc.run(mgArgs()...)
		if rc != 0 || !strings.Contains(out, "range-only") || sc.called("gh ") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("an ancestor check that cannot run refuses like a failed one", func(t *testing.T) {
		sc := newScn(t)
		sc.gitAns["merge-base --is-ancestor "+hBase+" "+hBase] = failWith(128, "fatal")
		out, _, rc := sc.run(mgArgs("--pr", "7")...)
		if !strings.HasPrefix(out, "merge-gate: refuse: base_excludes_pr_commits") || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}

func TestMerge(t *testing.T) {
	t.Run("merge after allow pins the reviewed head and squashes", func(t *testing.T) {
		sc := newScn(t)
		out, _, rc := sc.run(mergeArgs7()...)
		want := allowLine("passive", bound7) +
			"merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
		if out != want || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
		if !sc.called("gh pr merge 7 --squash --match-head-commit " + hHead) {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
	for _, tc := range []struct {
		name   string
		assess mgCmd
		prHead string
		want   string
	}{
		{"refuse", okOut(assessJSON("true", "high_risk")), hHead, "refuse: review_due"},
		{"degraded", okOut("{bad"), hHead, "degraded: assess output"},
		{"PR head mismatch", okOut(assessJSON("false", "passive")), hBase, "refuse: head_mismatch (PR #7"},
	} {
		t.Run("no merge on "+tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.assess, sc.prHead = tc.assess, tc.prHead
			out, _, rc := sc.run(mergeArgs7()...)
			if !strings.Contains(out, "merge-gate: "+tc.want) || rc == 0 || sc.called("gh pr merge") {
				t.Fatalf("out=%q rc=%d calls=%v", out, rc, sc.calls)
			}
		})
	}
	t.Run("no closure step without --merge", func(t *testing.T) {
		sc := newScn(t)
		out, _, _ := sc.run(mgArgs("--pr", "7")...)
		if strings.Contains(out, "closure-evidence") || sc.called("ghb") || sc.called("gh issue") {
			t.Fatalf("out=%q calls=%v", out, sc.calls)
		}
	})
	t.Run("a pure run makes no gh call at all", func(t *testing.T) {
		sc := newScn(t)
		sc.run(mgArgs()...)
		if sc.called("gh") || sc.called("git commit") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
	t.Run("an empty PR number with --merge never merges", func(t *testing.T) {
		sc := newScn(t)
		sc.checks = runsJSON("shellcheck:completed:success", "toolbelt-tests:completed:success")
		out, _, rc := sc.run(mgArgs("--merge", "")...)
		if rc != 0 || !strings.Contains(out, "range-only") || sc.called("gh pr merge") {
			t.Fatalf("out=%q rc=%d calls=%v", out, rc, sc.calls)
		}
	})
}

func TestMergeFailure(t *testing.T) {
	cases := []struct {
		name   string
		stdout string
		stderr string
		want   string
		rc     int
	}{
		{"degraded surfaces gh's first line", "", "X Pull request is not mergeable", "merge-gate: degraded: gh pr merge failed for PR #7: X Pull request is not mergeable\n", 3},
		{"no output", "", "", "merge-gate: degraded: gh pr merge failed for PR #7\n", 3},
		{"stdout counts too", "from stdout", "", "merge-gate: degraded: gh pr merge failed for PR #7: from stdout\n", 3},
		{"deprecation noise is skipped", "", "GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience\nX Pull request is not mergeable", "merge-gate: degraded: gh pr merge failed for PR #7: X Pull request is not mergeable\n", 3},
		{"deprecation is matched case-insensitively", "", "DEPRECATED thing\nreal error", "merge-gate: degraded: gh pr merge failed for PR #7: real error\n", 3},
		{"warning at the start of a line is skipped", "", "Warning: something\nreal error", "merge-gate: degraded: gh pr merge failed for PR #7: real error\n", 3},
		{"warning in the middle of a line is not noise", "", "X warning: inside", "merge-gate: degraded: gh pr merge failed for PR #7: X warning: inside\n", 3},
		{"only noise leaves no line", "", "deprecated\nwarning: x", "merge-gate: degraded: gh pr merge failed for PR #7\n", 3},
		{"line is cut to 200 bytes", "", strings.Repeat("z", 250), "merge-gate: degraded: gh pr merge failed for PR #7: " + strings.Repeat("z", 200) + "\n", 3},
		{"head rejection is a refuse", "", "Head branch was modified. Review and try the merge again.", "merge-gate: refuse: head_mismatch (PR #7 head changed before merge: Head branch was modified. Review and try the merge again.)\n", 1},
		{"head rejection behind a deprecation line", "", "GraphQL: Projects (classic) is being deprecated\nHead branch was modified. Review and try the merge again.", "merge-gate: refuse: head_mismatch (PR #7 head changed before merge: Head branch was modified. Review and try the merge again.)\n", 1},
		{"head rejection on a later line", "", "X Merge failed\nHead branch was modified. Review and try the merge again.", "merge-gate: refuse: head_mismatch (PR #7 head changed before merge: X Merge failed)\n", 1},
		{"match-head-commit mentioned", "", "--match-head-commit mismatch", "merge-gate: refuse: head_mismatch (PR #7 head changed before merge: --match-head-commit mismatch)\n", 1},
		{"head sha mentioned", "", "bad HEAD SHA", "merge-gate: refuse: head_mismatch (PR #7 head changed before merge: bad HEAD SHA)\n", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			sc.ghAns["pr merge"] = mgCmd{Stdout: []byte(tc.stdout), Stderr: []byte(tc.stderr), RC: 1}
			out, errOut, rc := sc.run(mergeArgs7()...)
			want := allowLine("passive", bound7) + tc.want
			if out != want || rc != tc.rc {
				t.Fatalf("out=%q\nwant %q rc=%d", out, want, rc)
			}
			if tc.rc == 3 && errOut != "DEGRADED: "+strings.TrimPrefix(strings.TrimSuffix(tc.want, "\n"), "merge-gate: degraded: ")+"\n" {
				t.Fatalf("stderr=%q", errOut)
			}
			if strings.Contains(out, "closure-evidence") {
				t.Fatal("a failed merge posts no closure evidence")
			}
		})
	}
}
