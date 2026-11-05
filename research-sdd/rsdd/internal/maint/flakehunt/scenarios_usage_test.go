package flakehunt

import "os"

// usageScenarios: bad usage and every degraded state before a hunt starts.
func usageScenarios() []scenario {
	one := suiteArgs("stable")
	return []scenario{
		{name: "help-short", raw: true, want: 0, diverges: true, args: sl("-h")},
		{name: "help-long", raw: true, want: 0, diverges: true, args: sl("--help")},
		{name: "unknown-flag", setup: std, want: 2, args: sl("--bogus")},
		{name: "runs-needs-value", setup: std, want: 2, raw: true, args: sl("--runs")},
		{name: "repo-needs-value", setup: std, want: 2, raw: true, args: sl("--repo")},
		{name: "evidence-needs-value", setup: std, want: 2, raw: true, args: sl("--evidence-url")},
		{name: "runs-zero", setup: std, want: 2, args: cat(sl("--runs", "0"), one)},
		{name: "runs-letters", setup: std, want: 2, args: cat(sl("--runs", "abc"), one)},
		{name: "runs-empty", setup: std, want: 2, args: cat(sl("--runs", ""), one)},
		{name: "runs-negative", setup: std, want: 2, args: cat(sl("--runs", "-2"), one)},
		{name: "load-negative", setup: std, want: 2, args: cat(sl("--load", "-1"), one)},
		{name: "load-letters", setup: std, want: 2, args: cat(sl("--load", "x"), one)},
		{name: "load-timeout-zero", setup: std, want: 2, args: cat(sl("--load", "0", "--load-timeout", "0"), one)},
		{name: "load-timeout-letters", setup: std, want: 2, args: cat(sl("--load", "0", "--load-timeout", "z"), one)},
		{name: "suite-timeout-zero", setup: std, want: 2, args: cat(sl("--load", "0", "--suite-timeout", "0"), one)},
		{name: "tier-bad", setup: std, want: 2, args: cat(sl("--tier", "mid"), one)},
		{name: "both-lists", setup: func(w *world) { w.standard(); w.file("empty", "") }, want: 2,
			args: cat(sl("--suites", "@W@/empty"), one)},
		{name: "evidence-not-url", setup: std, want: 2, args: cat(sl("--load", "0", "--evidence-url", "not a url"), one)},
		{name: "evidence-ftp", setup: std, want: 2, args: cat(sl("--load", "0", "--evidence-url", "ftp://x/y"), one)},
		{name: "evidence-space", setup: std, want: 2, args: cat(sl("--load", "0", "--evidence-url", "https://x/a b"), one)},
		{name: "no-timeout-tool", want: 2, setup: func(w *world) { w.standard(); w.drop("timeout") }, args: cat(sl("--load", "0"), one)},
		{name: "no-nproc-tool", want: 2, setup: func(w *world) { w.standard(); w.drop("nproc") }, args: cat(sl("--load", "0"), one)},
		{name: "no-node-for-mjs", want: 2, setup: func(w *world) {
			w.standard()
			w.suite("m.test.mjs", "exit 0")
		}, args: cat(sl("--load", "0"), sl("--suite", "s/m.test.mjs"))},
		{name: "no-node-shell-only", want: 0, setup: std, args: cat(sl("--load", "0"), one)},
		{name: "no-suite-source", setup: std, want: 2, args: sl("--load", "0")},
		{name: "empty-list", want: 2, setup: func(w *world) { w.standard(); w.file("empty", "") }, args: sl("--load", "0", "--suites", "@W@/empty")},
		{name: "comments-only-list", want: 2, setup: func(w *world) { w.standard(); w.file("c", "# a\n   \n#b\n") }, args: sl("--load", "0", "--suites", "@W@/c")},
		{name: "missing-suite", setup: std, want: 2, args: sl("--load", "0", "--suite", "s/nope.test.sh")},
		{name: "unreadable-list", setup: std, want: 2, args: sl("--load", "0", "--suites", "@W@/none")},
		{name: "repo-missing", raw: true, setup: std, want: 2, args: sl("--repo", "@W@/nope", "--out", "@O@", "--load", "0", "--suite", "s/x")},
	}
}

// outScenarios: the output directory is judged before anything is created or removed.
func outScenarios() []scenario {
	one := cat(sl("--runs", "1", "--load", "0"), suiteArgs("stable"))
	keep := func(w *world) {
		w.standard()
		w.file("repo/keep.txt", "keep\n")
		w.file("repo/research-sdd/x", "keep\n")
		w.file("ext/old.txt", "keep\n")
		if err := os.Symlink(w.repo, w.root+"/lnk"); err != nil {
			w.t.Fatal(err)
		}
		if err := os.MkdirAll(w.root+"/emptyout", 0o755); err != nil {
			w.t.Fatal(err)
		}
	}
	out := func(name, o, cwd string, want int) scenario {
		return scenario{name: name, setup: keep, raw: true, cwd: cwd, want: want, args: cat(sl("--repo", "@R@", "--out", o), one)}
	}
	return []scenario{
		out("out-is-repo", "@R@", "R", 2),
		out("out-dot-in-repo", ".", "R", 2),
		out("out-existing-repo-subdir", "@R@/research-sdd", "", 2),
		out("out-new-repo-subdir", "@R@/newdir", "", 2),
		out("out-dotdot-into-repo", "@R@/../repo/newdir2", "", 2),
		out("out-symlink-to-repo", "@W@/lnk", "", 2),
		out("out-nonempty", "@W@/ext", "", 2),
		out("out-empty-existing", "@W@/emptyout", "", 0),
		out("out-new", "@W@/fresh/deeper", "", 0),
		out("out-relative", "relout", "", 0),
		out("out-dotdot-below-missing", "@W@/nx/../y", "", 2),
		out("out-dot-below-missing", "@W@/nx/./y", "", 2),
		out("out-is-a-file", "@W@/ext/old.txt", "", 2).divergent(),
		{name: "xdg-state-home", raw: true, setup: std, want: 0, env: sl("XDG_STATE_HOME=@W@/xdg"),
			args: sl("--repo", "@R@", "--runs", "1", "--load", "0", "--suite", "s/stable.test.sh")},
		{name: "home-state-default", raw: true, setup: std, want: 0,
			args: sl("--repo", "@R@", "--runs", "1", "--load", "0", "--suite", "s/stable.test.sh")},
	}
}

// selectionScenarios: where the suite list comes from (run-all.sh) and the --tier handshake.
func selectionScenarios() []scenario {
	core, full := "s/stable.test.sh\n", "s/stable.test.sh\ns/skip.test.sh\n"
	withRA := func(w *world) { w.standard(); w.stubRunAll(core, full) }
	return []scenario{
		{name: "tier-default", setup: withRA, want: 0, args: sl("--runs", "1", "--load", "0")},
		{name: "tier-all-explicit", setup: withRA, want: 0, args: sl("--runs", "1", "--load", "0", "--tier", "all")},
		{name: "tier-core-rejected", setup: withRA, want: 0, args: sl("--runs", "1", "--load", "0", "--tier", "core")},
		{name: "tier-core-accepted", want: 0, setup: func(w *world) { withRA(w); w.file("rec/accept-tier", "") },
			args: sl("--runs", "1", "--load", "0", "--tier", "core")},
		{name: "run-all-failing", want: 2, setup: func(w *world) { withRA(w); w.file("rec/ra-fail", "") },
			args: sl("--runs", "1", "--load", "0")},
		{name: "run-all-absent", setup: std, want: 2, args: sl("--runs", "1", "--load", "0")},
		{name: "run-all-empty-listing", want: 2, setup: func(w *world) { w.standard(); w.stubRunAll("", "") },
			args: sl("--runs", "1", "--load", "0")},
	}
}
