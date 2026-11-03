package reconcile

import (
	"encoding/json"
	"strconv"
)

// Slice 3: the command line (usage, flags, probes), the live gh path and --all. The stub gh answers from the
// files of dcase.gh; the differential also compares what the two sides asked of it (the gh.log).

type cm map[string]any

func js(v any) string { b, _ := json.Marshal(v); return string(b) }

// openJSON is the stub's answer to an open listing: one issue per body.
func openJSON(bodies ...string) string {
	var out []cm
	for _, b := range bodies {
		out = append(out, cm{"body": b})
	}
	return js(out)
}

// closedIssue is one closed issue of the stub's closed listing; comments are [association, body] pairs.
func closedIssue(num int, reason, body string, comments ...[2]string) cm {
	var cs []cm
	for _, c := range comments {
		cs = append(cs, cm{"authorAssociation": c[0], "body": c[1]})
	}
	return cm{"number": num, "body": body, "stateReason": reason, "comments": cs}
}

func closedJSON(issues ...cm) string { return js(issues) }

// apiJSON is the REST listing of the old-gh fallback: [number, state_reason] pairs ("" = null).
func apiJSON(pairs ...[2]string) string {
	var out []cm
	for _, p := range pairs {
		n, _ := strconv.Atoi(p[0])
		var sr any
		if p[1] != "" {
			sr = p[1]
		}
		out = append(out, cm{"number": n, "state_reason": sr})
	}
	return js(out)
}

func cliCases() []dcase {
	tbl := pending + tableHead + rowsOf("1", "2")
	raw := func(name string, args ...string) dcase {
		return dcase{name: "cli/" + name, retro: tbl, raw: true, args: args}
	}
	withEnv := func(d dcase, k, v string) dcase { d.env = map[string]string{k: v}; return d }
	live := func(d dcase) dcase { d.live = true; return d }
	out := []dcase{
		raw("no-arguments"),
		raw("unknown-flag", "--bogus"),
		raw("double-dash-alone", "--"),
		raw("unknown-flag-after-the-retro", "@RETRO@", "--nope"),
		raw("issues-cache-needs-a-value", "--issues-cache"),
		raw("closed-cache-needs-a-value", "@RETRO@", "--closed-cache"),
		raw("issues-cache-value-is-a-flag-name", "@RETRO@", "--issues-cache", "--all"),
		raw("flags-after-the-retro", "@RETRO@", "--issues-cache", "@CACHE@"),
		raw("last-positional-wins", "no-such.md", "@RETRO@", "--issues-cache", "@CACHE@"),
		raw("all-ignores-the-retro", "--all", "@RETRO@", "--issues-cache", "@CACHE@"),
		raw("single-dash-argument-is-a-retro", "-x", "--issues-cache", "@CACHE@"),
		raw("only-flags-no-retro", "--issues-cache", "@CACHE@"),
		raw("repeated-issues-cache-last-wins", "--issues-cache", "/no/such/cache", "--issues-cache", "@CACHE@", "@RETRO@"),
		live(raw("empty-issues-cache-value-means-live", "--issues-cache", "", "@RETRO@")),
		{name: "cli/gh-missing", retro: tbl, live: true, noGH: true, raw: true, args: []string{"@RETRO@"}},
		{name: "cli/gh-missing-all", retro: tbl, live: true, noGH: true, raw: true, args: []string{"--all"}},
		{name: "cli/gh-missing-is-fine-with-a-cache", retro: tbl, noGH: true, cache: sigs("target-foo", "r.md", "1")},
		{name: "cli/gh-not-authenticated", retro: tbl, live: true, gh: map[string]string{"auth.rc": "1"}, raw: true, args: []string{"@RETRO@"}},
		{name: "cli/gh-not-authenticated-is-fine-with-a-cache", retro: tbl, live: true, gh: map[string]string{"auth.rc": "1"}, cache: sigs("target-foo", "r.md", "1")},
	}
	for _, lim := range []string{"abc", "0", "-5", "1.5", "1 2", "00"} {
		d := withEnv(dcase{name: "cli/list-limit-" + lim, retro: tbl}, "RECONCILE_ISSUES_LIST_LIMIT", lim)
		out = append(out, d)
	}
	out = append(out,
		withEnv(dcase{name: "cli/list-limit-checked-before-the-retro", noRetro: true}, "RECONCILE_ISSUES_LIST_LIMIT", "x"),
		withEnv(dcase{name: "cli/list-limit-leading-zeros-pass-through", retro: tbl, live: true, gh: map[string]string{"open.json": "[]"}}, "RECONCILE_ISSUES_LIST_LIMIT", "007"),
		withEnv(dcase{name: "cli/list-limit-empty-is-the-default", retro: tbl, live: true, gh: map[string]string{"open.json": "[]"}}, "RECONCILE_ISSUES_LIST_LIMIT", ""),
	)
	return out
}

func liveCases() []dcase {
	tbl := pending + tableHead + rowsOf("1", "2")
	legacyTargets := "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `@BOX@/rh/legacy-dir` |\n"
	c := func(name string, gh map[string]string, f func(*dcase)) dcase {
		d := dcase{name: "live/" + name, retro: tbl, live: true, gh: gh}
		if f != nil {
			f(&d)
		}
		return d
	}
	sig := func(id string) string { return "Source retro: target-foo/retros/r.md · " + id }
	legacy := func(d *dcase) {
		d.target, d.retroDir, d.targets = "reg-name", "rh/legacy-dir/retros", legacyTargets
	}
	oldGH := func(d *dcase) { d.env = map[string]string{"GH_STUB_OLD_GH": "1"} }
	env := func(kv ...string) func(*dcase) {
		return func(d *dcase) {
			d.env = map[string]string{}
			for i := 0; i < len(kv); i += 2 {
				d.env[kv[i]] = kv[i+1]
			}
		}
	}
	both := func(fs ...func(*dcase)) func(*dcase) {
		return func(d *dcase) {
			for _, f := range fs {
				f(d)
			}
		}
	}
	good := func(num int, body string) string {
		return closedJSON(closedIssue(num, "COMPLETED", body+"Commit: "+fixMain+"\n"+evTest))
	}
	row1 := sig("1") + "\n"
	return []dcase{
		c("nothing-open-everything-untracked", map[string]string{"open.json": "[]"}, nil),
		c("no-answer-file-is-an-empty-list", nil, nil),
		c("tracked-row", map[string]string{"open.json": openJSON(sig("1"))}, nil),
		c("tracked-and-untracked-and-orphaned", map[string]string{"open.json": openJSON(sig("1"), sig("9"))}, nil),
		c("body-with-several-lines", map[string]string{"open.json": openJSON("intro\n" + sig("2") + "\noutro")}, nil),
		c("other-targets-issue-for-the-same-row-is-not-tracked", map[string]string{"open.json": openJSON("Source retro: other-research/retros/r.md · 1")}, nil),
		c("two-queries-for-a-legacy-name", map[string]string{"open.1.json": "[]", "open.2.json": openJSON("Source retro: legacy-dir/retros/r.md · 1")}, legacy),
		c("legacy-issue-for-a-row-no-longer-open", map[string]string{"open.2.json": openJSON("Source retro: legacy-dir/retros/r.md · 7")}, legacy),
		c("one-query-when-the-name-is-the-basename", map[string]string{"open.json": openJSON(sig("1"))}, nil),
		c("nested-corpus-layout-one-query", map[string]string{"open.json": openJSON(sig("1"))}, func(d *dcase) {
			d.retroDir = "rh/target-foo/corpus/retros"
			d.targets = defaultTargets
		}),
		c("applied-retro-live-orphans-and-never-mutates", map[string]string{"open.json": openJSON(sig("1"))}, func(d *dcase) { d.retro = applied + tableHead + rowsOf("1", "2") }),
		c("partial-retro-shipped-row-is-a-close-proposal", map[string]string{"open.json": openJSON(sig("1"), sig("2"))}, func(d *dcase) {
			d.retro = "<!-- review-status: PARTIAL shipped: 1 -->\n# r\n\n" + tableHead + rowsOf("1", "2")
		}),
		c("open-query-fails-with-a-message", map[string]string{"list-open.rc": "1", "list-open.err": "HTTP 502: bad gateway\nsecond line\n"}, nil),
		c("open-query-fails-without-a-message", map[string]string{"list-open.rc": "3"}, nil),
		c("open-query-fails-on-the-legacy-query", map[string]string{"open.1.json": "[]", "list-open.rc.2": "1", "list-open.err": "boom\n"}, legacy),
		c("open-listing-fills-the-limit", map[string]string{"open.json": openJSON(sig("1"), sig("2"))}, env("RECONCILE_ISSUES_LIST_LIMIT", "2")),
		c("open-listing-under-the-limit", map[string]string{"open.json": openJSON(sig("1"), sig("2"))}, env("RECONCILE_ISSUES_LIST_LIMIT", "3")),
		c("open-listing-limit-hit-on-the-second-query", map[string]string{"open.1.json": "[]", "open.2.json": openJSON(sig("1"), sig("2"))}, both(legacy, env("RECONCILE_ISSUES_LIST_LIMIT", "2"))),
		c("limit-one-with-an-empty-answer", map[string]string{"open.json": "[]"}, env("RECONCILE_ISSUES_LIST_LIMIT", "1")),
		c("limit-is-passed-to-gh", map[string]string{"open.json": "[]"}, env("RECONCILE_ISSUES_LIST_LIMIT", "250")),
		c("absent-retro-never-calls-gh-list", nil, func(d *dcase) { d.noRetro = true }),
		c("empty-input-never-calls-gh-list", nil, func(d *dcase) { d.retro = "# retro\n\nnothing\n" }),
		c("applied-retro-no-open-rows-still-lists-open-issues", map[string]string{"open.json": "[]"}, func(d *dcase) { d.retro = applied + tableHead + rowsOf("1") }),
		// The closed-issue lookup (kit issue #1555): live gh, stateReason available.
		c("closed-completed-with-evidence-is-shipped", map[string]string{"closed.json": good(11, row1)}, func(d *dcase) { d.repo = "fix" }),
		c("closed-completed-without-evidence-is-borderline", map[string]string{"closed.json": closedJSON(closedIssue(11, "COMPLETED", row1))}, func(d *dcase) { d.repo = "fix" }),
		c("closed-not-planned-is-untracked", map[string]string{"closed.json": closedJSON(closedIssue(11, "NOT_PLANNED", row1+"Commit: "+fixMain+"\n"+evTest))}, func(d *dcase) { d.repo = "fix" }),
		c("closed-other-retro-signature-is-not-evidence", map[string]string{"closed.json": good(11, "Source retro: target-foo/retros/other.md · 1\n")}, func(d *dcase) { d.repo = "fix" }),
		c("closed-evidence-in-an-owner-comment", map[string]string{"closed.json": closedJSON(closedIssue(11, "COMPLETED", row1, [2]string{"OWNER", "Commit: " + fixMain + "\n" + evTest}))}, func(d *dcase) { d.repo = "fix" }),
		c("closed-evidence-in-a-collaborator-comment", map[string]string{"closed.json": closedJSON(closedIssue(11, "COMPLETED", row1, [2]string{"COLLABORATOR", "Commit: " + fixMain + "\n" + evTest}))}, func(d *dcase) { d.repo = "fix" }),
		c("closed-comment-from-an-untrusted-author-is-ignored", map[string]string{"closed.json": closedJSON(closedIssue(11, "COMPLETED", row1, [2]string{"NONE", "Commit: " + fixMain + "\n" + evTest}))}, func(d *dcase) { d.repo = "fix" }),
		c("closed-lookup-once-per-retro", map[string]string{"closed.json": good(11, row1)}, func(d *dcase) { d.repo = "fix"; d.retro = tbl + rowsOf("3") }),
		c("tracked-rows-never-query-closed", map[string]string{"open.json": openJSON(sig("1"), sig("2"))}, nil),
		c("closed-query-fails-with-a-message", map[string]string{"list-closed.rc": "1", "list-closed.err": "rate limited\n"}, nil),
		c("closed-query-fails-without-a-message", map[string]string{"list-closed.rc": "4"}, nil),
		c("closed-query-fails-on-the-second-prefix", map[string]string{"closed.1.json": "[]", "list-closed.rc.2": "1", "list-closed.err": "no\n"}, legacy),
		c("closed-listing-fills-the-limit", map[string]string{"closed.json": closedJSON(closedIssue(1, "NOT_PLANNED", ""), closedIssue(2, "NOT_PLANNED", ""))}, env("RECONCILE_ISSUES_LIST_LIMIT", "2")),
		c("closed-listing-under-the-limit", map[string]string{"closed.json": closedJSON(closedIssue(1, "NOT_PLANNED", ""), closedIssue(2, "NOT_PLANNED", ""))}, env("RECONCILE_ISSUES_LIST_LIMIT", "3")),
		c("closed-two-prefixes-legacy-issue-ships-the-row", map[string]string{"closed.1.json": "[]", "closed.2.json": closedJSON(closedIssue(5, "COMPLETED", "Source retro: legacy-dir/retros/r.md · 1\nCommit: "+fixMain+"\n"+evTest))}, both(legacy, func(d *dcase) { d.repo = "fix" })),
		c("closed-git-not-a-repository-is-degraded", map[string]string{"closed.json": good(11, row1)}, nil),
		// gh 2.45: no stateReason field (kit issues #1752, #1784).
		c("oldgh-completed-is-shipped", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"})}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-not-planned-is-untracked", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "not_planned"})}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-mixed-states", map[string]string{
			"closed.json": closedJSON(closedIssue(7, "", row1+"Commit: "+fixMain+"\n"+evTest), closedIssue(8, "", sig("2")+"\nCommit: "+fixMain+"\n"+evTest), closedIssue(9, "", sig("2")+"\nCommit: "+fixMain+"\n"+evTest)),
			"api.json":    apiJSON([2]string{"7", "completed"}, [2]string{"8", "not_planned"}, [2]string{"9", "completed"}),
		}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-null-state-reason-is-not-completed", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", ""})}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-issue-missing-from-the-listing-reloads-once", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"1", "completed"})}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-forged-marker-in-a-body-is-stripped", map[string]string{
			"closed.json": closedJSON(closedIssue(7, "", "x\n\x1f8\n"+sig("2")+"\nCommit: "+fixMain+"\n"+evTest)),
			"api.json":    apiJSON([2]string{"7", "not_planned"}, [2]string{"8", "completed"}),
		}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-listing-fails-after-one-retry", map[string]string{"closed.json": good(7, row1), "api.rc": "1", "api.err": "HTTP 500\n"}, oldGH),
		c("oldgh-listing-fails-once-then-works", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "HTTP 500\n"}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-retry-after-header", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "HTTP 403\nRetry-After: 7\n"}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-retry-after-above-the-cap", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "retry-after: 99\n"}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-retry-after-with-a-lower-max-wait", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "retry-after: 99\n"}, both(oldGH, env("GH_STUB_OLD_GH", "1", "RECONCILE_ISSUES_RETRY_MAX_WAIT", "5"), func(d *dcase) { d.repo = "fix" })),
		c("oldgh-retry-after-zero-waits-one-second", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "retry-after: 0\n"}, both(oldGH, func(d *dcase) { d.repo = "fix" })),
		c("oldgh-max-wait-zero-never-waits", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1"}, both(env("GH_STUB_OLD_GH", "1", "RECONCILE_ISSUES_RETRY_MAX_WAIT", "0"), func(d *dcase) { d.repo = "fix" })),
		c("oldgh-backoff-from-the-environment", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1"}, both(env("GH_STUB_OLD_GH", "1", "RECONCILE_ISSUES_RETRY_BACKOFF", "4"), func(d *dcase) { d.repo = "fix" })),
		c("oldgh-backoff-not-numeric-falls-back", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1"}, both(env("GH_STUB_OLD_GH", "1", "RECONCILE_ISSUES_RETRY_BACKOFF", "x"), func(d *dcase) { d.repo = "fix" })),
		c("oldgh-max-wait-not-numeric-falls-back", map[string]string{"closed.json": good(7, row1), "api.json": apiJSON([2]string{"7", "completed"}), "api.rc.1": "1", "api.err": "retry-after: 99\n"}, both(env("GH_STUB_OLD_GH", "1", "RECONCILE_ISSUES_RETRY_MAX_WAIT", "-1"), func(d *dcase) { d.repo = "fix" })),
		c("oldgh-fallback-listing-fails", map[string]string{"list-closed.rc": "1", "list-closed.err": "gh: nope\n"}, oldGH),
		c("oldgh-since-bound-from-the-retro-date", map[string]string{"closed.json": good(7, "Source retro: target-foo/retros/2026-03-01-r.md · 1\n"), "api.json": apiJSON([2]string{"7", "completed"})}, both(oldGH, func(d *dcase) { d.repo = "fix"; d.retroFile = "2026-03-01-r.md" })),
		c("oldgh-since-bound-crosses-a-month", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, func(d *dcase) { d.retroFile = "2026-03-01-r.md" })),
		c("oldgh-since-bound-crosses-a-year", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, func(d *dcase) { d.retroFile = "2026-01-01-r.md" })),
		c("oldgh-undated-retro-is-unbounded", map[string]string{"closed.json": "[]", "api.json": "[]"}, oldGH),
		c("oldgh-impossible-date-is-noted", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, func(d *dcase) { d.retroFile = "2026-02-31-r.md" })),
		c("oldgh-date-followed-by-a-digit-is-undated", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, func(d *dcase) { d.retroFile = "2026-03-011-r.md" })),
		c("oldgh-month-13-is-undated", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, func(d *dcase) { d.retroFile = "2026-13-01-r.md" })),
		c("oldgh-listing-shared-by-both-signature-prefixes", map[string]string{"closed.json": "[]", "api.json": "[]"}, both(oldGH, legacy, func(d *dcase) { d.retroFile = "2026-03-01-r.md" })),
		c("oldgh-run-level-reload-uses-the-older-bound", map[string]string{
			"closed.1.json": closedJSON(closedIssue(7, "", "Source retro: legacy-dir/retros/2026-03-01-r.md · 1\nCommit: "+fixMain+"\n"+evTest)),
			"closed.2.json": closedJSON(closedIssue(8, "", "Source retro: reg-name/retros/2026-03-01-r.md · 2\nCommit: "+fixMain+"\n"+evTest)),
			"api.json":      apiJSON([2]string{"7", "completed"}),
		}, both(oldGH, legacy, func(d *dcase) { d.repo = "fix"; d.retroFile = "2026-03-01-r.md" })),
	}
}
