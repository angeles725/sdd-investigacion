package flakehunt

// issueScenarios: --file-issues (dry) and =apply against the gh stub, including the de-duplication that the CI
// workflow relies on (an open issue whose title starts with `flake: <suite file> ` is commented on, never duplicated).
func issueScenarios() []scenario {
	flaky := cat(sl("--runs", "2", "--load", "0"), suiteArgs("flaky"))
	withGH := func(w *world) { w.standard(); w.stubGH() }
	existing := func(lines string) func(*world) {
		return func(w *world) { withGH(w); w.file("rec/gh-existing", lines) }
	}
	return []scenario{
		{name: "dry-creates", setup: withGH, want: 1, args: cat(sl("--file-issues"), flaky)},
		{name: "dry-comments-existing", setup: existing("77\tflake: flaky.test.sh failed 1/2 under CPU load\n"), want: 1,
			args: cat(sl("--file-issues"), flaky)},
		{name: "dry-near-misses-do-not-dedupe", want: 1, args: cat(sl("--file-issues"), flaky),
			setup: existing("88\tflake: myflaky.test.sh failed 1/2 under CPU load\n89\tflake: flaky.test.sh.old failed 1/2\n90\tFLAKE: flaky.test.sh failed\n91\tfix flake: flaky.test.sh failed\n")},
		{name: "dry-first-match-wins", want: 1, args: cat(sl("--file-issues"), flaky),
			setup: existing("5\tunrelated\n6\tflake: flaky.test.sh failed 1/2\n7\tflake: flaky.test.sh failed 2/2\n")},
		{name: "dry-search-fails", want: 1, args: cat(sl("--file-issues"), flaky),
			setup: func(w *world) { withGH(w); w.file("rec/gh-fail", "") }},
		{name: "dry-without-gh", setup: std, want: 1, args: cat(sl("--file-issues"), flaky)},
		{name: "apply-creates", setup: withGH, want: 1, args: cat(sl("--file-issues=apply"), flaky)},
		{name: "apply-comments-existing", setup: existing("77\tflake: flaky.test.sh failed 1/2 under CPU load\n"), want: 1,
			args: cat(sl("--file-issues=apply", "--evidence-url", "https://example.invalid/o/r/actions/runs/42"), flaky)},
		{name: "apply-search-fails-files-nothing", want: 2, args: cat(sl("--file-issues=apply"), flaky),
			setup: func(w *world) { withGH(w); w.file("rec/gh-fail", "") }},
		{name: "apply-create-fails", want: 2, args: cat(sl("--file-issues=apply"), flaky),
			setup: func(w *world) { withGH(w); w.file("rec/gh-mutfail", "") }},
		{name: "apply-without-gh", setup: std, want: 2, args: cat(sl("--file-issues=apply"), flaky)},
		{name: "apply-broken-is-filed", setup: withGH, want: 1,
			args: cat(sl("--file-issues=apply", "--runs", "2", "--load", "0"), suiteArgs("stable", "broken"))},
		{name: "apply-two-suites", setup: withGH, want: 1,
			args: cat(sl("--file-issues=apply", "--runs", "2", "--load", "0"), suiteArgs("flaky", "broken", "stable"))},
		{name: "apply-nothing-to-file", setup: withGH, want: 0,
			args: cat(sl("--file-issues=apply", "--runs", "2", "--load", "0"), suiteArgs("stable", "skip"))},
		{name: "dry-nothing-to-file", setup: withGH, want: 0,
			args: cat(sl("--file-issues", "--runs", "2", "--load", "0"), suiteArgs("stable"))},
		{name: "no-file-issues-no-gh", setup: withGH, want: 1, args: flaky},
	}
}

// issueEdgeScenarios: names that cannot be filed, quoting of the printed command and the evidence line.
func issueEdgeScenarios() []scenario {
	hunt := sl("--runs", "2", "--load", "0")
	return []scenario{
		{name: "unsafe-suite-name", want: 2, setup: func(w *world) {
			w.stubGH()
			w.suite("we ird.test.sh", bodyBroken)
		}, args: cat(sl("--file-issues"), hunt, sl("--suite", "s/we ird.test.sh"))},
		{name: "quoted-print-of-special-name", want: 2, setup: func(w *world) {
			w.stubGH()
			w.suite("it's.test.sh", bodyBroken)
		}, args: cat(sl("--file-issues=apply"), hunt, sl("--suite", "s/it's.test.sh"))},
		{name: "unsafe-name-does-not-stop-the-rest", want: 2, setup: func(w *world) {
			w.stubGH()
			w.suite("we ird.test.sh", bodyBroken)
			w.suite("ok.test.sh", bodyBroken)
		}, args: cat(sl("--file-issues"), hunt, sl("--suite", "s/we ird.test.sh", "--suite", "s/ok.test.sh"))},
		{name: "evidence-in-body", want: 1, setup: func(w *world) { w.standard(); w.stubGH() },
			args: cat(sl("--file-issues=apply", "--evidence-url", "http://example.invalid/run/1"), hunt, suiteArgs("flaky"))},
		{name: "no-evidence-line", want: 1, setup: func(w *world) { w.standard(); w.stubGH() },
			args: cat(sl("--file-issues=apply"), hunt, suiteArgs("flaky"))},
		{name: "prove-teeth-in-body", want: 1, setup: func(w *world) { w.standard(); w.stubGH() },
			args: cat(sl("--file-issues", "--prove-teeth"), hunt, suiteArgs("broken"))},
	}
}
