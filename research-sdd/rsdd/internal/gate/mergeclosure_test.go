package gate

import (
	"fmt"
	"strings"
	"testing"
)

const (
	ceTestA = "research-sdd/toolbelt/tests/foo.test.sh"
	ceTestB = "research-sdd/install/tests/bar.test.sh"
)

// gql builds the GraphQL answer: merged state oid total node... where a node is "owner/repo#N" and the answer
// is about repository o/r.
func gql(merged, state, oid string, total int, nodes ...string) string {
	return gqlRepo("o/r", merged, state, oid, total, nodes...)
}

func gqlRepo(repo, merged, state, oid string, total int, nodes ...string) string {
	var ns []string
	for _, n := range nodes {
		r, num, _ := strings.Cut(n, "#")
		ns = append(ns, fmt.Sprintf(`{"number":%s,"repository":{"nameWithOwner":%q}}`, num, r))
	}
	mc := "null"
	if oid != "null" {
		mc = fmt.Sprintf(`{"oid":%q}`, oid)
	}
	return fmt.Sprintf(`{"data":{"repository":{"nameWithOwner":%q,"pullRequest":{"merged":%s,"state":%q,"mergeCommit":%s,"closingIssuesReferences":{"totalCount":%d,"nodes":[%s]}}}}}`,
		repo, merged, state, mc, total, strings.Join(ns, ","))
}

func filesWithStatus(entries ...string) string {
	var es []string
	for _, e := range entries {
		st, name, _ := strings.Cut(e, ":")
		es = append(es, fmt.Sprintf(`{"status":%q,"filename":%q}`, st, name))
	}
	return "[" + strings.Join(es, ",") + "]"
}

var ceTests = filesWithStatus("modified:research-sdd/toolbelt/foo.sh", "added:"+ceTestA, "added:"+ceTestB, "removed:research-sdd/toolbelt/tests/gone.test.sh")

// ceScn is a --merge run that reaches the closure step: no required checks, one green PR check.
func ceScn(t *testing.T, files, graphql string) *scn {
	sc := newScn(t)
	sc.environ = append(sc.environ, "MERGE_GATE_REQUIRED_CHECKS=")
	sc.checks = runsJSON("pr-validation:completed:success")
	sc.files = files
	sc.gql = graphql
	return sc
}

const ceMerged = "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\n"

func ceRun(sc *scn, extra ...string) (closure string, rc int) {
	out, _, rc := sc.run(mgArgs(append([]string{"--merge", "7"}, extra...)...)...)
	_, after, ok := strings.Cut(out, ceMerged)
	if !ok {
		sc.t.Fatalf("no merge happened: %q", out)
	}
	return after, rc
}

func comments(sc *scn) []string {
	var cs []string
	for _, c := range sc.calls {
		if strings.HasPrefix(c, "gh issue comment ") {
			cs = append(cs, c)
		}
	}
	return cs
}

func ceLine(s string) string { return "merge-gate: closure-evidence: " + s + "\n" }

func TestClosurePosts(t *testing.T) {
	sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 2, "o/r#41", "o/r#42"))
	out, rc := ceRun(sc)
	want := ceLine("posted: issue #41 (commit="+hMerge+" tests=2)") + ceLine("posted: issue #42 (commit="+hMerge+" tests=2)")
	if out != want || rc != 0 {
		t.Fatalf("out=%q rc=%d", out, rc)
	}
	body := "Closure evidence (merge-gate, PR #7):\n- commit: " + hMerge + "\n- test: " + ceTestB + "\n- test: " + ceTestA
	cs := comments(sc)
	if len(cs) != 2 || cs[0] != "gh issue comment 41 --repo o/r --body "+body || cs[1] != "gh issue comment 42 --repo o/r --body "+body {
		t.Fatalf("comments=%q", cs)
	}
	if strings.Contains(strings.Join(cs, ""), "gone.test.sh") {
		t.Fatal("a removed test file is not evidence")
	}
	if !sc.called("ghb api graphql -F owner=o -F name=r -F pr=7 -f query=query($owner:String!") || !sc.called("ghb repo view --json nameWithOwner -q .nameWithOwner") {
		t.Fatalf("calls=%v", sc.calls)
	}
	if !sc.called("gh api repos/o/r/pulls/7/files?per_page=100 --paginate") {
		t.Fatalf("the files are read from the resolved repo: %v", sc.calls)
	}
}

func TestClosureRepository(t *testing.T) {
	t.Run("GH_REPO decides, no repo view", func(t *testing.T) {
		sc := ceScn(t, ceTests, gqlRepo("acme/fork", "true", "MERGED", hMerge, 2, "acme/fork#41", "acme/fork#42"))
		sc.environ = append(sc.environ, "GH_REPO=acme/fork")
		out, _ := ceRun(sc)
		if !strings.Contains(out, "posted: issue #41") || sc.called("ghb repo view") {
			t.Fatalf("out=%q calls=%v", out, sc.calls)
		}
		if !sc.called("ghb api graphql -F owner=acme -F name=fork") || !sc.called("gh issue comment 41 --repo acme/fork") || !sc.called("gh api repos/acme/fork/pulls/7/files") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
	forms := []struct{ env, repo string }{{"host/o/r", "o/r"}, {"r", "r/r"}, {"o/r", "o/r"}}
	for _, f := range forms {
		t.Run("GH_REPO="+f.env, func(t *testing.T) {
			sc := ceScn(t, ceTests, gqlRepo(f.repo, "true", "MERGED", hMerge, 1, f.repo+"#41"))
			sc.environ = append(sc.environ, "GH_REPO="+f.env)
			out, _ := ceRun(sc)
			if !strings.Contains(out, "posted: issue #41") {
				t.Fatalf("out=%q", out)
			}
		})
	}
	t.Run("an empty GH_REPO falls back to the cwd remote", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 1, "o/r#41"))
		sc.environ = append(sc.environ, "GH_REPO=")
		out, _ := ceRun(sc)
		if !strings.Contains(out, "posted") || !sc.called("ghb repo view") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("the answer is for another repository than the merge used", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 2, "o/r#41"))
		sc.environ = append(sc.environ, "GH_REPO=acme/fork")
		out, _ := ceRun(sc)
		if out != ceLine("degraded: the GraphQL answer is for repository o/r but the merge used acme/fork; nothing posted") || len(comments(sc)) != 0 {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("repository names compare case-insensitively", func(t *testing.T) {
		sc := ceScn(t, ceTests, gqlRepo("O/R", "true", "MERGED", hMerge, 1, "O/R#41"))
		out, _ := ceRun(sc)
		if !strings.Contains(out, "posted: issue #41") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("repo view fails", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 1, "o/r#41"))
		sc.ghbAns["repo view"] = failWith(1, "gh: repo view failed\nmore\n")
		out, _ := ceRun(sc)
		if out != ceLine("degraded: cannot resolve the repository the merge used (gh repo view: gh: repo view failed); nothing posted") {
			t.Fatalf("out=%q", out)
		}
	})
	for _, bad := range []string{"not a repo", "justone", "a/b/c", "o/r\nx/y", "", "o/"} {
		t.Run(fmt.Sprintf("repo view garbage %q", bad), func(t *testing.T) {
			sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 1, "o/r#41"))
			sc.ghbAns["repo view"] = okOut(bad + "\n")
			out, _ := ceRun(sc)
			want := ceLine("degraded: cannot resolve the repository the merge used (got '" + strings.TrimRight(bad, "\n") + "'); nothing posted")
			if out != want || len(comments(sc)) != 0 {
				t.Fatalf("out=%q", out)
			}
		})
	}
}

func TestClosureGuards(t *testing.T) {
	notMerged := ceLine("degraded: PR #7 is not reported merged (merged!=true or state!=MERGED); nothing posted")
	noOID := ceLine("degraded: PR #7 has no usable 40-hex merge commit oid; nothing posted")
	bad := ceLine("degraded: the GraphQL answer for PR #7 is unparseable or off-schema; nothing posted")
	cases := []struct{ name, gql, want string }{
		{"merged=false", gql("false", "MERGED", hMerge, 1, "o/r#41"), notMerged},
		{"state=OPEN", gql("true", "OPEN", hMerge, 1, "o/r#41"), notMerged},
		{"null oid", gql("true", "MERGED", "null", 1, "o/r#41"), noOID},
		{"short oid", gql("true", "MERGED", "abc1234", 1, "o/r#41"), noOID},
		{"41-char oid", gql("true", "MERGED", hMerge+"a", 1, "o/r#41"), noOID},
		{"non-hex oid", gql("true", "MERGED", strings.Repeat("g", 40), 1, "o/r#41"), noOID},
		{"malformed", "{not json", bad},
		{"empty", "", bad},
		{"repository null", `{"data":{"repository":null}}`, bad},
		{"no data", `{}`, bad},
		{"pull request null", `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":null}}}`, bad},
		{"nodes missing", `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","closingIssuesReferences":{"totalCount":1}}}}}`, bad},
		{"totalCount missing", `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","closingIssuesReferences":{"nodes":[]}}}}}`, bad},
		{"data is a string", `{"data":"x"}`, bad},
		{"merge commit is a string", `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":"x","closingIssuesReferences":{"totalCount":0,"nodes":[]}}}}}`, bad},
		{"nameWithOwner not a string", `{"data":{"repository":{"nameWithOwner":5,"pullRequest":{}}}}`, bad},
		{"two answers", gql("true", "MERGED", hMerge, 1, "o/r#41") + gql("true", "MERGED", hMerge, 1, "o/r#41"), bad},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := ceScn(t, ceTests, tc.gql)
			out, rc := ceRun(sc)
			if out != tc.want || rc != 0 || len(comments(sc)) != 0 {
				t.Fatalf("out=%q rc=%d comments=%q", out, rc, comments(sc))
			}
		})
	}
	t.Run("an oid with one trailing newline still passes like jq's $", func(t *testing.T) {
		sc := ceScn(t, ceTests, `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"`+hMerge+`\n"},"closingIssuesReferences":{"totalCount":1,"nodes":[{"number":41,"repository":{"nameWithOwner":"o/r"}}]}}}}}`)
		out, _ := ceRun(sc)
		if !strings.Contains(out, "posted: issue #41 (commit="+hMerge+" ") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("a valid answer followed by a value jq cannot index is still read", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 1, "o/r#41")+" 5")
		out, _ := ceRun(sc)
		if !strings.Contains(out, "posted: issue #41") {
			t.Fatalf("out=%q", out)
		}
	})
}

func TestClosureGraphQLFailures(t *testing.T) {
	t.Run("timeout", func(t *testing.T) {
		sc := ceScn(t, ceTests, "")
		sc.ghbAns["api graphql"] = mgCmd{RC: 124, Timeout: true}
		out, rc := ceRun(sc)
		if out != ceLine("degraded: GraphQL read of PR #7 timed out (bound MERGE_GATE_GH_TIMEOUT, default 30 s); nothing posted") || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("gh error", func(t *testing.T) {
		sc := ceScn(t, ceTests, "")
		sc.ghbAns["api graphql"] = failWith(1, "gh: HTTP 502\nx\n")
		out, rc := ceRun(sc)
		if out != ceLine("degraded: cannot read the closing issues of PR #7 (gh api graphql exit 1: gh: HTTP 502); nothing posted") || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}

func TestClosureIssues(t *testing.T) {
	t.Run("cross-repo nodes are noted, never commented, same-repo case-insensitively", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 3, "o/r#41", "other/x#9", "O/R#43"))
		out, _ := ceRun(sc)
		want := ceLine("note: PR #7 also closes other/x#9 in another repository; no evidence posted there") +
			ceLine("posted: issue #41 (commit="+hMerge+" tests=2)") + ceLine("posted: issue #43 (commit="+hMerge+" tests=2)")
		if out != want {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("totalCount over 50 is a typed degraded note and still posts", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 51, "o/r#41"))
		out, _ := ceRun(sc)
		want := ceLine("degraded: PR #7 closes 51 issues but only the first 50 were read; backfill the other 1 by hand") + ceLine("posted: issue #41 (commit="+hMerge+" tests=2)")
		if out != want {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("exactly 50 is no overflow", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 50, "o/r#41"))
		out, _ := ceRun(sc)
		if strings.Contains(out, "backfill") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("no closing issue", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 0))
		out, _ := ceRun(sc)
		if out != ceLine("none: PR #7 closes no issue in o/r (closingIssuesReferences has none)") || sc.called("gh api repos/o/r") {
			t.Fatalf("out=%q calls=%v", out, sc.calls)
		}
	})
	t.Run("issues are sorted numerically and unique", func(t *testing.T) {
		sc := ceScn(t, ceTests, gql("true", "MERGED", hMerge, 4, "o/r#100", "o/r#9", "o/r#100", "o/r#42"))
		ceRun(sc)
		var got []string
		for _, c := range comments(sc) {
			got = append(got, strings.Fields(c)[3])
		}
		if strings.Join(got, ",") != "9,42,100" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("issue numbers below 1 or fractional are not issues", func(t *testing.T) {
		raw := `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"` + hMerge + `"},"closingIssuesReferences":{"totalCount":4,"nodes":[` +
			`{"number":0,"repository":{"nameWithOwner":"o/r"}},{"number":1.5,"repository":{"nameWithOwner":"o/r"}},{"number":"7","repository":{"nameWithOwner":"o/r"}},{"number":1,"repository":{"nameWithOwner":"o/r"}}]}}}}}`
		sc := ceScn(t, ceTests, raw)
		ceRun(sc)
		if cs := comments(sc); len(cs) != 1 || !strings.HasPrefix(cs[0], "gh issue comment 1 ") {
			t.Fatalf("comments=%q", cs)
		}
	})
	t.Run("a null cross-repo node is noted as null", func(t *testing.T) {
		raw := `{"data":{"repository":{"nameWithOwner":"o/r","pullRequest":{"merged":true,"state":"MERGED","mergeCommit":{"oid":"` + hMerge + `"},"closingIssuesReferences":{"totalCount":2,"nodes":[` +
			`{"number":5,"repository":{"nameWithOwner":null}},{"number":1,"repository":{"nameWithOwner":"o/r"}}]}}}}}`
		sc := ceScn(t, ceTests, raw)
		out, _ := ceRun(sc)
		if !strings.Contains(out, "also closes null#5 in another repository") {
			t.Fatalf("out=%q", out)
		}
	})
}

func TestClosureTestFiles(t *testing.T) {
	g := gql("true", "MERGED", hMerge, 1, "o/r#41")
	t.Run("no test file posts nothing", func(t *testing.T) {
		files := filesWithStatus("modified:research-sdd/toolbelt/foo.sh", "modified:docs/x.md", "added:research-sdd/toolbelt/tests/fixtures/f.test.sh.txt", "added:research-sdd/tests/a/b.test.sh")
		sc := ceScn(t, files, g)
		out, _ := ceRun(sc)
		if out != ceLine("not posted: PR #7 changes no test file (research-sdd/**/tests/*.test.sh); a commit without a test is not shipped evidence") || len(comments(sc)) != 0 {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("the test path grammar", func(t *testing.T) {
		for name, want := range map[string]bool{
			"research-sdd/tests/a.test.sh":            true,
			"research-sdd/toolbelt/tests/a.test.sh":   true,
			"research-sdd/a/b/tests/a.test.sh":        true,
			"research-sdd/toolbelt/tests/x/a.test.sh": false,
			"research-sdd/toolbelt/tests/a.test.sh.x": false,
			"xresearch-sdd/toolbelt/tests/a.test.sh":  false,
			"research-sdd/toolbelt/tests/a_test.sh":   false,
			"research-sdd/toolbelt/tests/atest.sh":    false,
			"research-sdd/toolbelt/test/a.test.sh":    false,
			"research-sdd/toolbelt/tests/.test.sh":    false,
		} {
			files, ok := changedTestFiles(filesWithStatus("added:" + name))
			if !ok || (len(files) == 1) != want {
				t.Errorf("%s: files=%v want %v", name, files, want)
			}
		}
	})
	t.Run("a test file only on page 2 counts", func(t *testing.T) {
		sc := ceScn(t, filesWithStatus("modified:docs/x.md")+"\n"+filesWithStatus("added:"+ceTestA), g)
		out, _ := ceRun(sc)
		if out != ceLine("posted: issue #41 (commit="+hMerge+" tests=1)") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("cap 10 lists ten and says so", func(t *testing.T) {
		var es []string
		for i := 1; i <= 12; i++ {
			es = append(es, fmt.Sprintf("added:research-sdd/toolbelt/tests/t%02d.test.sh", i))
		}
		sc := ceScn(t, filesWithStatus(es...), g)
		out, _ := ceRun(sc)
		want := ceLine("note: 2 test file(s) beyond cap 10 not listed") + ceLine("posted: issue #41 (commit="+hMerge+" tests=10)")
		if out != want || strings.Count(strings.Join(comments(sc), ""), "- test: ") != 10 || strings.Contains(strings.Join(comments(sc), ""), "t11.test.sh") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("exactly 10 has no cap note", func(t *testing.T) {
		var es []string
		for i := 1; i <= 10; i++ {
			es = append(es, fmt.Sprintf("added:research-sdd/toolbelt/tests/t%02d.test.sh", i))
		}
		sc := ceScn(t, filesWithStatus(es...), g)
		out, _ := ceRun(sc)
		if strings.Contains(out, "note:") || !strings.Contains(out, "tests=10)") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("files read failure", func(t *testing.T) {
		sc := ceScn(t, ceTests, g)
		sc.ghAns["api repos/o/r/pulls/7/files?per_page=100"] = failWith(1, "")
		out, rc := ceRun(sc)
		if out != ceLine("degraded: cannot read the files of PR #7 (gh api failed)") || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	for name, files := range map[string]string{"malformed": "{nope", "not an array": `{"a":1}`, "empty": "", "entry without status": `[3]`} {
		t.Run("unparseable files: "+name, func(t *testing.T) {
			sc := ceScn(t, files, g)
			out, _ := ceRun(sc)
			if out != ceLine("degraded: files of PR #7 are unparseable or off-schema") {
				t.Fatalf("out=%q", out)
			}
		})
	}
}

func TestClosureComments(t *testing.T) {
	g := gql("true", "MERGED", hMerge, 2, "o/r#41", "o/r#42")
	t.Run("failing comments are typed and backfilled, the exit stays 0", func(t *testing.T) {
		sc := ceScn(t, ceTests, g)
		sc.ghAns["issue comment"] = failWith(1, "gh: HTTP 403 forbidden\nx\n")
		out, rc := ceRun(sc)
		want := ceLine("degraded: could not comment on issue #41 (gh exit 1: gh: HTTP 403 forbidden)") +
			ceLine("degraded: could not comment on issue #42 (gh exit 1: gh: HTTP 403 forbidden)") +
			ceLine("degraded: not posted for issues: #41 #42 (backfill by hand)")
		if out != want || rc != 0 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("--no-closure-evidence opts out and makes no read", func(t *testing.T) {
		sc := ceScn(t, ceTests, g)
		out, rc := ceRun(sc, "--no-closure-evidence")
		if out != ceLine("skipped: --no-closure-evidence") || rc != 0 || sc.called("ghb") || len(comments(sc)) != 0 {
			t.Fatalf("out=%q calls=%v", out, sc.calls)
		}
	})
	t.Run("a failed merge posts nothing", func(t *testing.T) {
		sc := ceScn(t, ceTests, g)
		sc.ghAns["pr merge"] = failWith(1, "boom")
		out, _, rc := sc.run(mgArgs("--merge", "7")...)
		if strings.Contains(out, "closure-evidence") || rc != 3 || sc.called("ghb") {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}
