package gate

import (
	"fmt"
	"strings"
	"testing"
)

// cr builds one check-run object: name:status:conclusion[:app[:id]] (empty conclusion = null, app 0 = none).
func cr(spec string) string {
	p := strings.Split(spec, ":")
	for len(p) < 5 {
		p = append(p, "")
	}
	concl := "null"
	if p[2] != "" {
		concl = fmt.Sprintf("%q", p[2])
	}
	id := "900000"
	if p[4] != "" {
		id = p[4]
	}
	app := ""
	if p[3] != "" {
		app = `,"app":{"id":` + p[3] + `}`
	}
	return fmt.Sprintf(`{"id":%s,"name":%q,"status":%q,"conclusion":%s%s}`, id, p[0], p[1], concl, app)
}

func runsJSON(specs ...string) string {
	var rs []string
	for _, s := range specs {
		rs = append(rs, cr(s))
	}
	return checkRuns(rs...)
}

func verdictOf(t *testing.T, req string, specs ...string) string {
	t.Helper()
	runs, err := parseCheckRuns(runsJSON(specs...))
	if err != nil {
		t.Fatal(err)
	}
	latest, _ := ciNormalize(runs)
	return ciVerdict(latest, ciRequired(req))
}

func TestCIVerdict(t *testing.T) {
	const both = "shellcheck,toolbelt-tests"
	green := []string{"shellcheck:completed:success", "toolbelt-tests:completed:success", "pr-validation:completed:success"}
	with := func(pos int, bad string) []string {
		out := append([]string(nil), green...)
		out[pos] = bad
		return out
	}
	t.Run("green passes, skipped and neutral count as green", func(t *testing.T) {
		if v := verdictOf(t, both, green...); v != "ok" {
			t.Fatal(v)
		}
		if v := verdictOf(t, both, "shellcheck:completed:success", "toolbelt-tests:completed:skipped", "pr-validation:completed:neutral"); v != "ok" {
			t.Fatal(v)
		}
	})
	states := []struct{ st, want string }{
		{"queued:", "ci_pending"}, {"in_progress:", "ci_pending"}, {"waiting:", "ci_pending"},
		{"completed:failure", "ci_failed"}, {"completed:cancelled", "ci_failed"}, {"completed:timed_out", "ci_failed"}, {"completed:action_required", "ci_failed"},
		{"completed:stale", "ci_failed"}, {"completed:", "ci_failed"},
	}
	names := []string{"shellcheck", "toolbelt-tests", "pr-validation"}
	for _, s := range states {
		for pos, n := range names { // the offender FIRST, MIDDLE and LAST of three reported checks
			t.Run(s.st+"/"+n, func(t *testing.T) {
				want := s.want + " (" + n + ")"
				if v := verdictOf(t, both, with(pos, n+":"+s.st)...); v != want {
					t.Fatalf("got %q want %q", v, want)
				}
			})
		}
		t.Run(s.st+"/single", func(t *testing.T) {
			if v := verdictOf(t, "shellcheck", "shellcheck:"+s.st); v != s.want+" (shellcheck)" {
				t.Fatal(v)
			}
		})
	}
	t.Run("a failure outranks a pending check", func(t *testing.T) {
		if v := verdictOf(t, both, "shellcheck:in_progress:", "toolbelt-tests:completed:failure"); v != "ci_failed (toolbelt-tests)" {
			t.Fatal(v)
		}
	})
	t.Run("failed and pending names are sorted and unique", func(t *testing.T) {
		if v := verdictOf(t, "", "z:completed:failure", "a:completed:failure", "m:completed:failure:2"); v != "ci_failed (a,m,z)" {
			t.Fatal(v)
		}
		if v := verdictOf(t, "", "b:queued:", "a:queued:", "b:queued::7"); v != "ci_pending (a,b)" {
			t.Fatal(v)
		}
	})
	t.Run("missing: the absent name first, middle, last and single", func(t *testing.T) {
		cases := []struct {
			req   string
			specs []string
			want  string
		}{
			{"a,b,c", []string{"b:completed:success", "c:completed:success"}, "ci_missing (a)"},
			{"a,b,c", []string{"a:completed:success", "c:completed:success"}, "ci_missing (b)"},
			{"a,b,c", []string{"a:completed:success", "b:completed:success"}, "ci_missing (c)"},
			{"a", []string{"other:completed:success"}, "ci_missing (a)"},
			{"a,b,a", []string{"x:completed:success"}, "ci_missing (a,b,a)"},
			{"a.b", []string{"axb:completed:success"}, "ci_missing (a.b)"},
			{" shellcheck , toolbelt-tests ,", []string{"shellcheck:completed:success", "toolbelt-tests:completed:success"}, "ok"},
			{"", []string{"pr-validation:completed:success"}, "ok"},
			{both, []string{"pr-validation:completed:success"}, "ci_missing (shellcheck,toolbelt-tests)"},
		}
		for _, c := range cases {
			if v := verdictOf(t, c.req, c.specs...); v != c.want {
				t.Errorf("req %q: got %q want %q", c.req, v, c.want)
			}
		}
	})
	t.Run("no run reported is pending, never a pass", func(t *testing.T) {
		if v := verdictOf(t, ""); v != "ci_pending (no check runs reported)" {
			t.Fatal(v)
		}
		if v := verdictOf(t, both); v != "ci_pending (no check runs reported)" {
			t.Fatal(v)
		}
	})
	t.Run("an empty list still judges reported checks", func(t *testing.T) {
		if v := verdictOf(t, "", "pr-validation:in_progress:"); v != "ci_pending (pr-validation)" {
			t.Fatal(v)
		}
		if v := verdictOf(t, "", "pr-validation:completed:failure"); v != "ci_failed (pr-validation)" {
			t.Fatal(v)
		}
	})
}

func TestCINormalize(t *testing.T) {
	// latest = highest check-run id per (name, app id): listing order and started_at never decide.
	cases := []struct {
		name  string
		specs []string
		want  string
		notes []string
	}{
		{"older failed, newer success", []string{"shellcheck:completed:failure:1:10", "shellcheck:completed:success:1:20"}, "ok", nil},
		{"newer listed first", []string{"shellcheck:completed:success:1:20", "shellcheck:completed:failure:1:10"}, "ok", nil},
		{"older success, newer failed", []string{"shellcheck:completed:success:1:10", "shellcheck:completed:failure:1:20"}, "ci_failed (shellcheck)", nil},
		{"newer failed listed first", []string{"shellcheck:completed:failure:1:20", "shellcheck:completed:success:1:10"}, "ci_failed (shellcheck)", nil},
		{"older success, newer pending", []string{"shellcheck:completed:success:1:10", "shellcheck:in_progress::1:20"}, "ci_pending (shellcheck)", nil},
		{"older failed, newer queued rerun", []string{"shellcheck:completed:failure:1:10", "shellcheck:queued::1:20"}, "ci_pending (shellcheck)", nil},
		{"two apps: one failed", []string{"shellcheck:completed:success:1:20", "shellcheck:completed:failure:2:10"}, "ci_failed (shellcheck)", nil},
		{"two apps, each latest green", []string{"shellcheck:completed:failure:1:10", "shellcheck:completed:success:1:20", "shellcheck:completed:success:2:11"}, "ok", nil},
		{"ids compare numerically", []string{"shellcheck:completed:failure:1:9", "shellcheck:completed:success:1:10"}, "ok", nil},
		{"equal ids: the last listed is latest", []string{"shellcheck:completed:failure:1:5", "shellcheck:completed:success:1:5"}, "ok", nil},
		{"equal ids: the last listed failed", []string{"shellcheck:completed:success:1:5", "shellcheck:completed:failure:1:5"}, "ci_failed (shellcheck)", nil},
		{"cancelled then success is noted", []string{"shellcheck:completed:cancelled:1:10", "shellcheck:completed:success:1:20"}, "ok",
			[]string{"superseded cancelled run of shellcheck (check-run id 10, superseded by id 20)"}},
		{"cancelled listed last is noted", []string{"shellcheck:completed:success:1:20", "shellcheck:completed:cancelled:1:10"}, "ok",
			[]string{"superseded cancelled run of shellcheck (check-run id 10, superseded by id 20)"}},
		{"success then cancelled: the cancelled run is latest", []string{"shellcheck:completed:success:1:10", "shellcheck:completed:cancelled:1:20"}, "ci_failed (shellcheck)", nil},
		{"only cancelled", []string{"shellcheck:completed:cancelled:1:10"}, "ci_failed (shellcheck)", nil},
		{"cancelled of another app is not superseded", []string{"shellcheck:completed:cancelled:2:10", "shellcheck:completed:success:1:20"}, "ci_failed (shellcheck)", nil},
		{"older failure is judged silently", []string{"shellcheck:completed:failure:1:10", "shellcheck:completed:success:1:20"}, "ok", nil},
		{"a pending older cancelled-looking run is not noted", []string{"shellcheck:in_progress::1:10", "shellcheck:completed:success:1:20"}, "ok", nil},
		{"two cancelled notes follow the group order", []string{"b:completed:cancelled:1:1", "b:completed:success:1:2", "a:completed:cancelled:1:3", "a:completed:success:1:4"}, "ok",
			[]string{"superseded cancelled run of a (check-run id 3, superseded by id 4)", "superseded cancelled run of b (check-run id 1, superseded by id 2)"}},
		{"app id order: a null app sorts before a number", []string{"s:completed:cancelled::1", "s:completed:cancelled:3:2", "s:completed:success:3:5", "s:completed:success::9"}, "ok",
			[]string{"superseded cancelled run of s (check-run id 1, superseded by id 9)", "superseded cancelled run of s (check-run id 2, superseded by id 5)"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			runs, err := parseCheckRuns(runsJSON(tc.specs...))
			if err != nil {
				t.Fatal(err)
			}
			latest, notes := ciNormalize(runs)
			if v := ciVerdict(latest, nil); v != tc.want {
				t.Fatalf("verdict %q want %q", v, tc.want)
			}
			if strings.Join(notes, "|") != strings.Join(tc.notes, "|") {
				t.Fatalf("notes %q want %q", notes, tc.notes)
			}
		})
	}
}

func TestParseCheckRuns(t *testing.T) {
	bad := map[string]string{
		"empty":                "",
		"malformed":            "{not json",
		"no check_runs":        `{"total_count":1}`,
		"check_runs not array": `{"check_runs":{}}`,
		"page is an array":     `[]`,
		"run without a name":   `{"check_runs":[{"id":1,"status":"completed","conclusion":"success"}]}`,
		"run without a status": `{"check_runs":[{"id":1,"name":"a"}]}`,
		"run without an id":    `{"check_runs":[{"name":"a","status":"completed","conclusion":"success"}]}`,
		"string id":            `{"check_runs":[{"id":"7","name":"a","status":"completed"}]}`,
		"numeric name":         `{"check_runs":[{"id":1,"name":7,"status":"completed"}]}`,
		"run is not an object": `{"check_runs":[3]}`,
		"second page bad":      `{"check_runs":[]}` + "\n" + `{"nope":1}`,
		"garbage after pages":  `{"check_runs":[]} garbage`,
	}
	for name, raw := range bad {
		t.Run(name, func(t *testing.T) {
			if _, err := parseCheckRuns(raw); err == nil {
				t.Fatal("accepted")
			}
		})
	}
	t.Run("two pages are concatenated", func(t *testing.T) {
		raw := runsJSON("pr-validation:completed:success") + "\n" + runsJSON("shellcheck:completed:success")
		runs, err := parseCheckRuns(raw)
		if err != nil || len(runs) != 2 {
			t.Fatalf("runs=%d err=%v", len(runs), err)
		}
	})
	t.Run("an empty page list is fine", func(t *testing.T) {
		if runs, err := parseCheckRuns(`{"check_runs":[]}`); err != nil || len(runs) != 0 {
			t.Fatalf("runs=%d err=%v", len(runs), err)
		}
	})
	t.Run("app id forms", func(t *testing.T) {
		raw := `{"check_runs":[` +
			`{"id":1,"name":"a","status":"x","app":"str"},` +
			`{"id":2,"name":"a","status":"x","app":null},` +
			`{"id":3,"name":"a","status":"x","app":{"id":false}},` +
			`{"id":4,"name":"a","status":"x","app":{"id":0}}]}`
		runs, err := parseCheckRuns(raw)
		if err != nil {
			t.Fatal(err)
		}
		got := []string{string(runs[0].appID), string(runs[1].appID), string(runs[2].appID), string(runs[3].appID)}
		if strings.Join(got, ",") != "null,null,null,0" {
			t.Fatalf("%v", got)
		}
	})
}

// mergeArgs7 is a --merge run with the closure step off, so the verdict lines are the only output.
func mergeArgs7(extra ...string) []string {
	return mgArgs(append([]string{"--merge", "7", "--no-closure-evidence"}, extra...)...)
}

func noFilesNote(chk string) string {
	return "merge-gate: note: required check " + chk + " not evaluated against path filters: the PR reports no changed files; stays required\n"
}

func TestCIGateFlow(t *testing.T) {
	const head = "head=" + hHead
	allow := "merge-gate: allow: passive (head=" + hHead + " base=main merge_base=" + hBase + ") (bound to PR #7: head equal, range starts at or before the PR branch point)\n"
	merged := "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\n" + "merge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	cases := []struct {
		name    string
		checks  string
		environ []string
		extra   []string
		want    string
		rc      int
		stderr  string
	}{
		{"green merges", "", nil, nil, allow + merged, 0, ""},
		{"failed refuses", runsJSON("shellcheck:completed:failure", "toolbelt-tests:completed:success"), nil, nil,
			"merge-gate: refuse: ci_failed (shellcheck) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"pending refuses", runsJSON("shellcheck:completed:success", "toolbelt-tests:queued:"), nil, nil,
			"merge-gate: refuse: ci_pending (toolbelt-tests) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"missing refuses", runsJSON("shellcheck:completed:success"), nil, nil,
			noFilesNote("toolbelt-tests") + "merge-gate: refuse: ci_missing (toolbelt-tests) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"env opt-out waives only the names", runsJSON("pr-validation:completed:success"), []string{"MERGE_GATE_REQUIRED_CHECKS="}, nil, allow + merged, 0, ""},
		{"flag opt-out overrides the env", runsJSON("pr-validation:completed:success"), []string{"MERGE_GATE_REQUIRED_CHECKS=shellcheck"}, []string{"--required-checks", ""}, allow + merged, 0, ""},
		{"default set without the env", runsJSON("pr-validation:completed:success"), nil, nil,
			noFilesNote("shellcheck") + noFilesNote("toolbelt-tests") + "merge-gate: refuse: ci_missing (shellcheck,toolbelt-tests) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"flag overrides the env", runsJSON("shellcheck:completed:success"), []string{"MERGE_GATE_REQUIRED_CHECKS=a,b"}, []string{"--required-checks", "shellcheck"}, allow + merged, 0, ""},
		{"flag adds a name", runsJSON("shellcheck:completed:success"), nil, []string{"--required-checks", "shellcheck,nope"},
			noFilesNote("nope") + "merge-gate: refuse: ci_missing (nope) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"env list is used when no flag", runsJSON("a:completed:success"), []string{"MERGE_GATE_REQUIRED_CHECKS=a,b"}, nil,
			noFilesNote("b") + "merge-gate: refuse: ci_missing (b) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"zero reported checks", `{"total_count":0,"check_runs":[]}`, []string{"MERGE_GATE_REQUIRED_CHECKS="}, nil,
			"merge-gate: refuse: ci_pending (no check runs reported) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"malformed", "{not json", nil, nil, "merge-gate: degraded: check runs for head " + hHead + " are unparseable or off-schema\n", 3, "DEGRADED: check runs for head " + hHead + " are unparseable or off-schema\n"},
		{"no id", `{"check_runs":[{"name":"shellcheck","status":"completed","conclusion":"success"}]}`, nil, nil,
			"merge-gate: degraded: check runs for head " + hHead + " are unparseable or off-schema\n", 3, "DEGRADED: check runs for head " + hHead + " are unparseable or off-schema\n"},
		{"two pages: failure only on page 2", runsJSON("shellcheck:completed:success") + "\n" + runsJSON("toolbelt-tests:completed:failure"), nil, nil,
			"merge-gate: refuse: ci_failed (toolbelt-tests) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
		{"two pages: required check only on page 2", runsJSON("pr-validation:completed:success") + "\n" + runsJSON("shellcheck:completed:success"), nil, []string{"--required-checks", "shellcheck"}, allow + merged, 0, ""},
		{"superseded cancelled run is a note before the allow", runsJSON("shellcheck:completed:cancelled:1:10", "shellcheck:completed:success:1:20", "toolbelt-tests:completed:success"), nil, nil,
			"merge-gate: note: superseded cancelled run of shellcheck (check-run id 10, superseded by id 20)\n" + allow + merged, 0, ""},
		{"the note also prints on the refuse path", runsJSON("shellcheck:completed:cancelled:1:10", "shellcheck:completed:success:1:20", "toolbelt-tests:completed:failure"), nil, nil,
			"merge-gate: note: superseded cancelled run of shellcheck (check-run id 10, superseded by id 20)\nmerge-gate: refuse: ci_failed (toolbelt-tests) (" + head + ") — CI for this exact head must be green before merging\n", 1, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := newScn(t)
			if tc.checks != "" {
				sc.checks = tc.checks
			}
			sc.environ = append(sc.environ, tc.environ...)
			out, errOut, rc := sc.run(mergeArgs7(tc.extra...)...)
			if out != tc.want || errOut != tc.stderr || rc != tc.rc {
				t.Fatalf("out=%q\nwant %q err=%q rc=%d", out, tc.want, errOut, rc)
			}
			if rc != 0 && sc.called("gh pr merge") {
				t.Fatal("a refused or degraded gate must never call gh pr merge")
			}
			if !sc.called("gh api repos/{owner}/{repo}/commits/" + hHead + "/check-runs?per_page=100 --paginate") {
				t.Fatalf("the check runs are read for the exact head: %v", sc.calls)
			}
		})
	}
	t.Run("gh error surfaces its stderr as one line", func(t *testing.T) {
		sc := newScn(t)
		sc.ghAns["api repos/{owner}/{repo}/commits/"+hHead+"/check-runs?per_page=100"] = failWith(1, "gh: HTTP 502\nsecond\n")
		out, _, rc := sc.run(mergeArgs7()...)
		if out != "merge-gate: degraded: cannot read check runs for head "+hHead+" (gh api failed: gh: HTTP 502 second )\n" || rc != 3 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("gh error without stderr has no detail", func(t *testing.T) {
		sc := newScn(t)
		sc.ghAns["api repos/{owner}/{repo}/commits/"+hHead+"/check-runs?per_page=100"] = failWith(1, "")
		out, _, rc := sc.run(mergeArgs7()...)
		if out != "merge-gate: degraded: cannot read check runs for head "+hHead+" (gh api failed)\n" || rc != 3 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
	t.Run("gh error detail is cut to 300 bytes", func(t *testing.T) {
		sc := newScn(t)
		sc.ghAns["api repos/{owner}/{repo}/commits/"+hHead+"/check-runs?per_page=100"] = failWith(1, strings.Repeat("e", 400))
		out, _, _ := sc.run(mergeArgs7()...)
		if !strings.Contains(out, "(gh api failed: "+strings.Repeat("e", 300)+")") {
			t.Fatalf("out=%q", out)
		}
	})
	t.Run("--pr alone never reads check runs; review_due refuses before any read", func(t *testing.T) {
		sc := newScn(t)
		sc.run(mgArgs("--pr", "7")...)
		if sc.called("gh api repos/{owner}/{repo}/commits/") {
			t.Fatalf("calls=%v", sc.calls)
		}
		sc = newScn(t)
		sc.assess = okOut(assessJSON("true", "high_risk"))
		sc.run(mergeArgs7()...)
		if sc.called("gh api repos/{owner}/{repo}/commits/") || sc.called("gh pr merge") {
			t.Fatalf("calls=%v", sc.calls)
		}
	})
}
