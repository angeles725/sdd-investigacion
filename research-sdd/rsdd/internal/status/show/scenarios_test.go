package show

func f(kv ...string) files {
	m := files{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}

func a(args ...string) []string { return args }

func env(kv ...string) map[string]string {
	m := map[string]string{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}

// argsPickScenarios is the argument-parsing, state-pick, BOOTSTRAP and --emit-token table.
func argsPickScenarios() []scenario {
	one := f("corpus/RESEARCH-STATE.md", probeState)
	dirOnly := f("corpus/", "")
	two := f("corpus/RESEARCH-STATE.md", probeState, "corpus/RESEARCH-STATE-x.md", probeState)
	queue := f("corpus/RESEARCH-STATE.md", "# RESEARCH-STATE\n## Campaign queue\n- G1\n")
	siblings := f("corpus/sub/RESEARCH-STATE.md", probeState, "corpus/sub/RESEARCH-STATE-a.md", probeState)
	verdict := func(v string) map[string]string { return env("PROBE_VERDICT", v) }
	scs := []scenario{
		// usage and flag validation
		{name: "usage-no-args", args: a()},
		{name: "usage-not-a-dir", args: a("nope")},
		{name: "usage-target-is-file", files: f("plain", "x"), args: a("plain")},
		{name: "usage-unknown-flag", files: one, args: a("corpus", "--bogus")},
		{name: "usage-unknown-flag-after-valid", files: one, args: a("corpus", "--next", "--bogus")},
		{name: "usage-target-looks-like-flag", files: one, args: a("--next")},
		{name: "only-needs-sync-state", files: one, args: a("corpus", "--only", "covered_blocks")},
		{name: "only-needs-sync-state-with-next", files: one, args: a("corpus", "--only", "covered_blocks", "--next")},
		{name: "only-whitespace", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks, blocked_open")},
		{name: "only-tab", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks\tx")},
		{name: "only-empty", files: one, args: a("corpus", "--sync-state", "--only", "")},
		{name: "only-missing-value", files: one, args: a("corpus", "--sync-state", "--only")},
		{name: "only-leading-comma", files: one, args: a("corpus", "--sync-state", "--only", ",covered_blocks")},
		{name: "only-trailing-comma", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks,")},
		{name: "only-double-comma", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks,,blocked_open")},
		{name: "only-unknown-counter", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks,nope")},
		{name: "only-each-counter-valid", files: one, args: a("corpus", "--sync-state", "--only", "covered_blocks,gaps_closed,known_gaps,investigable_open,requires_execution_open,blocked_open,deferred_open,undocumented_findings")},
		{name: "only-prefix-of-counter-is-unknown", files: one, args: a("corpus", "--sync-state", "--only", "blocked")},
		{name: "root-and-focus-exclusive", files: one, args: a("corpus", "--root", "--focus", "x")},
		{name: "all-needs-next", files: one, args: a("corpus", "--all")},
		{name: "all-excludes-focus", files: one, args: a("corpus", "--next", "--all", "--focus", "x")},
		{name: "all-excludes-root", files: one, args: a("corpus", "--next", "--all", "--root")},
		{name: "all-next-ok", files: one, args: a("corpus", "--next", "--all")},
		{name: "emit-token-needs-next", files: one, args: a("corpus", "--emit-token")},
		{name: "emit-token-needs-next-sync", files: one, args: a("corpus", "--sync-state", "--emit-token")},
		{name: "queue-needs-next", files: one, args: a("corpus", "--queue")},
		{name: "queue-next-ok", files: one, args: a("corpus", "--next", "--queue")},
		{name: "focus-missing-slug", files: one, args: a("corpus", "--focus")},
		{name: "stall-zero", files: one, args: a("corpus", "--stall-minutes", "0")},
		{name: "stall-zeros", files: one, args: a("corpus", "--stall-minutes", "000")},
		{name: "stall-alpha", files: one, args: a("corpus", "--stall-minutes", "abc")},
		{name: "stall-negative", files: one, args: a("corpus", "--stall-minutes", "-5")},
		{name: "stall-decimal", files: one, args: a("corpus", "--stall-minutes", "1.5")},
		{name: "stall-missing-value", files: one, args: a("corpus", "--stall-minutes")},
		{name: "stall-leading-zeros-ok", files: one, args: a("corpus", "--stall-minutes", "0007")},
		{name: "stall-ok", files: one, args: a("corpus", "--stall-minutes", "30")},
		{name: "stall-int64-max", files: one, args: a("corpus", "--stall-minutes", "9223372036854775807")},
		{name: "mode-last-wins-sync", files: one, args: a("corpus", "--next", "--sync-state")},
		{name: "mode-last-wins-next", files: one, args: a("corpus", "--sync-state", "--next")},
		{name: "focus-flag-parsed", files: f("corpus/RESEARCH-STATE-x.md", probeState), args: a("corpus", "--next", "--focus", "x")},

		// default pick
		{name: "pick-root-state", files: one, args: a("corpus")},
		{name: "pick-nested-only", files: f("corpus/sub/RESEARCH-STATE.md", probeState), args: a("corpus")},
		{name: "pick-root-beats-focus-sibling", files: two, args: a("corpus")},
		{name: "pick-shallowest-first", files: f("corpus/a/RESEARCH-STATE-z.md", probeState, "corpus/RESEARCH-STATE-y.md", probeState), args: a("corpus")},
		{name: "pick-ambiguous-same-depth-takes-first", files: f("corpus/b/RESEARCH-STATE.md", probeState, "corpus/a/RESEARCH-STATE.md", probeState), args: a("corpus")},
		{name: "pick-template-ignored", files: f("corpus/RESEARCH-STATE.template.md", probeState), args: a("corpus", "--next")},
		{name: "pick-git-dir-ignored", files: f("corpus/.git/RESEARCH-STATE.md", probeState), args: a("corpus", "--next")},
		{name: "pick-beyond-maxdepth-ignored", files: f("corpus/a/b/c/RESEARCH-STATE.md", probeState), args: a("corpus", "--next")},
		{name: "pick-at-maxdepth", files: f("corpus/a/b/RESEARCH-STATE.md", probeState), args: a("corpus")},
		{name: "pick-state-is-a-directory", files: f("corpus/RESEARCH-STATE.md/", ""), args: a("corpus", "--next")},
		{name: "pick-trailing-slash-target", files: one, args: a("corpus/")},
		{name: "pick-dot-target", files: one, cwd: "corpus", args: a(".")},
		{name: "pick-absolute-target", files: one, args: a("{ROOT}/corpus", "--next")},
		{name: "pick-target-with-space", files: f("my corpus/RESEARCH-STATE.md", probeState), args: a("my corpus")},
		{name: "pick-dotdot-target", files: f("corpus/RESEARCH-STATE.md", probeState, "other/", ""), cwd: "other", args: a("../corpus")},

		// BOOTSTRAP
		{name: "bootstrap-status", files: dirOnly, args: a("corpus")},
		{name: "bootstrap-next", files: dirOnly, args: a("corpus", "--next")},
		{name: "bootstrap-sync-state", files: dirOnly, args: a("corpus", "--sync-state")},
		{name: "bootstrap-trailing-slash", files: dirOnly, args: a("corpus/", "--next")},

		// --focus
		{name: "focus-found", files: f("corpus/RESEARCH-STATE-x.md", probeState, "corpus/RESEARCH-STATE-y.md", probeState), args: a("corpus", "--focus", "x")},
		{name: "focus-missing-next", files: one, args: a("corpus", "--next", "--focus", "nope")},
		{name: "focus-missing-status", files: one, args: a("corpus", "--focus", "nope")},
		{name: "focus-missing-sync-state", files: one, args: a("corpus", "--sync-state", "--focus", "nope")},
		{name: "focus-glob-slug", files: f("corpus/RESEARCH-STATE-xy.md", probeState), args: a("corpus", "--focus", "x*")},
		{name: "focus-same-slug-two-dirs-takes-first", files: f("corpus/b/RESEARCH-STATE-x.md", probeState, "corpus/a/RESEARCH-STATE-x.md", probeState), args: a("corpus", "--focus", "x")},
		{name: "focus-does-not-match-root-file", files: one, args: a("corpus", "--focus", "")},

		// --root
		{name: "root-top-level", files: two, args: a("corpus", "--root")},
		{name: "root-top-level-next", files: two, args: a("corpus", "--next", "--root")},
		{name: "root-none-status", files: dirOnly, args: a("corpus", "--root")},
		{name: "root-none-next", files: dirOnly, args: a("corpus", "--next", "--root")},
		{name: "root-none-sync-state", files: dirOnly, args: a("corpus", "--sync-state", "--root")},
		{name: "root-only-focus-files", files: f("corpus/RESEARCH-STATE-a.md", probeState), args: a("corpus", "--next", "--root")},
		{name: "root-nested-beside-siblings", files: siblings, args: a("corpus", "--root")},
		{name: "root-nested-without-siblings-refused", files: f("corpus/archive/RESEARCH-STATE.md", probeState), args: a("corpus", "--root")},
		{name: "root-two-nested-with-siblings-refused", files: f(
			"corpus/a/RESEARCH-STATE.md", probeState, "corpus/a/RESEARCH-STATE-q.md", probeState,
			"corpus/b/RESEARCH-STATE.md", probeState, "corpus/b/RESEARCH-STATE-r.md", probeState), args: a("corpus", "--root")},
		{name: "root-one_with_siblings_one_without_picks_the_first", files: f(
			"corpus/a/RESEARCH-STATE.md", probeState, "corpus/a/RESEARCH-STATE-q.md", probeState,
			"corpus/b/RESEARCH-STATE.md", probeState), args: a("corpus", "--root")},
		{name: "root-template-sibling-does-not-count", files: f("corpus/sub/RESEARCH-STATE.md", probeState, "corpus/sub/RESEARCH-STATE-a.template.md", probeState), args: a("corpus", "--root")},
		{name: "root-state-is-a-directory", files: f("corpus/RESEARCH-STATE.md/", ""), args: a("corpus", "--root")},
		{name: "root-git-candidate-ignored", files: f("corpus/.git/RESEARCH-STATE.md", probeState, "corpus/.git/RESEARCH-STATE-a.md", probeState), args: a("corpus", "--next", "--root")},

		// --emit-token
		{name: "emit-bootstrap-has-no-token", files: dirOnly, args: a("corpus", "--next", "--emit-token")},
		{name: "emit-no-verdict-line", files: one, args: a("corpus", "--next", "--emit-token")},
		{name: "emit-flag-first", files: one, args: a("corpus", "--emit-token", "--next", "--queue")},
		{name: "emit-flag-twice", files: one, args: a("corpus", "--emit-token", "--next", "--emit-token"), env: verdict("NEXT | P1 | G1")},
		{name: "emit-next", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1 | G7")},
		{name: "emit-next-no-gap", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1")},
		{name: "emit-next-empty-gap", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1 | ")},
		{name: "emit-next-gap-keeps-later-pipes", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1 | G | x")},
		{name: "emit-next-indented-verdict", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("   NEXT | P2 | G9  ")},
		{name: "emit-next-with-trailing-note", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1 | G1\nWARN: queue-malformed")},
		{name: "emit-two-verdict-lines", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("NEXT | P1 | A\nSTOP | done")},
		{name: "emit-blank-output-is-no-verdict", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict(" ")},
		{name: "emit-bare-stop-prefix-is-no-verdict", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | ")},
		{name: "emit-silent-next", files: one, args: a("corpus", "--next", "--emit-token"), env: env("PROBE_SILENT", "1")},
		{name: "emit-next-rc-gate-3", files: one, args: a("corpus", "--next", "--emit-token"), env: env("PROBE_VERDICT", "NEXT | P | G", "PROBE_RC", "3")},
		{name: "emit-next-rc-gate-1", files: one, args: a("corpus", "--next", "--emit-token"), env: env("PROBE_VERDICT", "NEXT | P | G", "PROBE_RC", "1")},
		{name: "emit-stop-single-state", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | read-only-investigable exhausted (0)")},
		{name: "emit-stop-with-campaign-queue", files: queue, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | read-only-investigable exhausted (0)")},
		{name: "emit-stop-queue-heading-needs-line-start", files: f("corpus/RESEARCH-STATE.md", "x ## Campaign queue\n  ## Campaign queue\n"), args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-queue-heading-first-line", files: f("corpus/RESEARCH-STATE.md", "## Campaign queue\n"), args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-two-state-files", files: two, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-focus-scoped-multi", files: two, args: a("corpus", "--next", "--focus", "x", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-root-scoped-multi", files: two, args: a("corpus", "--next", "--root", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-backlog-unreadable", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0) [backlog-unreadable: 2 rows]")},
		{name: "emit-stop-backlog-unverified", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0) [issue-coverage: unverified] [backlog-unreadable: unverified]")},
		{name: "emit-stop-unreadable-state", files: one, unreadable: []string{"corpus/RESEARCH-STATE.md"}, needsUser: true, args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-stop-template-not-counted", files: f("corpus/RESEARCH-STATE.md", probeState, "corpus/RESEARCH-STATE.template.md", probeState), args: a("corpus", "--next", "--emit-token"), env: verdict("STOP | exhausted (0)")},
		{name: "emit-issues-due-has-no-token", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("ISSUES-DUE | 2 untracked delta(s) in retros/x.md")},
		{name: "emit-retro-due-has-no-token", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("RETRO-DUE | 7 blocks")},
		{name: "emit-stale-has-no-token", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("STALE | run --sync-state")},
		{name: "emit-bootstrap-verdict-has-no-token", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("BOOTSTRAP | no RESEARCH-STATE under corpus")},
		{name: "emit-lowercase-verdict-is-no-verdict", files: one, args: a("corpus", "--next", "--emit-token"), env: verdict("next | P1 | G1")},
		{name: "emit-with-focus-pick", files: f("corpus/RESEARCH-STATE-x.md", probeState), args: a("corpus", "--next", "--focus", "x", "--emit-token")},
		{name: "emit-usage-error-is-not-masked", files: one, args: a("corpus", "--next", "--emit-token", "--bogus")},
		{name: "emit-root-refusal-propagates", files: f("corpus/archive/RESEARCH-STATE.md", probeState), args: a("corpus", "--next", "--root", "--emit-token")},
	}
	return scs
}
