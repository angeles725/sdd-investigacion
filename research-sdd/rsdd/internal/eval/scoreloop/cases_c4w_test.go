package scoreloop

// c4WindowCases: block commits after the STOP moment, the default-window rescan, the grace window, and the
// transcript-span witness (kit issue #1017).
func c4WindowCases() []scase {
	// The run spans 00:00-00:25 and its STOP is at 00:25 (cleanRun). Commits are added after it.
	after := func(name string, commits []commit, t *string, args []string, env ...string) scase {
		return scase{name: "c4w-" + name, commits: append(append([]commit(nil), twoBlocks...), commits...), transcript: t, args: args, env: envOf(env...)}
	}
	full := func(date, subject string) commit { return commit{date, subject} }
	wide := []string{"--corpus", "{{CORPUS}}", "--transcript", "{{TRANSCRIPT}}", "--since", ts("00:00"), "--until", "2026-06-03T00:00:00Z"}
	tail := func(extra ...string) *string {
		lines := []string{human(ts("00:00"), "start"), asst(ts("00:25"), "finished\nSTOP: campaign complete")}
		return jl(append(lines, extra...)...)
	}
	return []scase{
		after("none-after-stop", nil, cleanRun(), nil),
		after("commit-five-minutes-after-counts", []commit{cm("00:30", "research(demo): B3 c")}, cleanRun(), nil),
		after("commit-same-second-as-stop-counts", []commit{cm("00:25", "research(demo): B3 c")}, cleanRun(), nil),
		after("commit-one-second-before-stop-does-not", []commit{full("2026-06-01T00:24:59Z", "research(demo): B3 c")}, cleanRun(), nil),
		after("commit-exactly-at-grace-end-counts", []commit{cm("00:35", "research(demo): B3 c")}, cleanRun(), nil),
		after("commit-one-second-past-grace-is-unwitnessed", []commit{full("2026-06-01T00:35:01Z", "research(demo): B3 c")}, cleanRun(), nil),
		after("commit-days-later-is-unwitnessed", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), nil),
		after("grace-zero-makes-five-minutes-unwitnessed", []commit{cm("00:30", "research(demo): B3 c")}, cleanRun(), nil, "RSDD_C4_AFTER_STOP_GRACE", "0"),
		after("grace-zero-same-second-still-counts", []commit{cm("00:25", "research(demo): B3 c")}, cleanRun(), nil, "RSDD_C4_AFTER_STOP_GRACE", "0"),
		after("grace-huge-counts-days-later", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), nil, "RSDD_C4_AFTER_STOP_GRACE", "100000"),
		after("grace-one-minute", []commit{cm("00:26", "research(demo): B3 c"), cm("00:28", "research(demo): B4 d")}, cleanRun(), nil, "RSDD_C4_AFTER_STOP_GRACE", "1"),
		after("inside-transcript-span-counts-despite-zero-grace", []commit{cm("00:35", "research(demo): B3 c")}, tail(toolRes(ts("00:40"))), nil, "RSDD_C4_AFTER_STOP_GRACE", "0"),
		after("after-last-record-and-grace-is-unwitnessed", []commit{cm("00:50", "research(demo): B3 c")}, tail(toolRes(ts("00:40"))), nil, "RSDD_C4_AFTER_STOP_GRACE", "0"),
		after("range-weights-commits-after-stop", []commit{cm("00:30", "research(demo): B3-B6 c")}, cleanRun(), nil),
		after("range-weights-unwitnessed", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3-B5 c")}, cleanRun(), nil),
		after("counted-and-unwitnessed-together", []commit{cm("00:30", "research(demo): B3 c"), full("2026-06-02T00:00:00Z", "research(demo): B4-B5 d")}, cleanRun(), nil),
		after("non-block-commit-after-stop-ignored", []commit{cm("00:30", "chore: tidy")}, cleanRun(), nil),
		after("implausible-range-after-stop-warns-again", []commit{cm("00:30", "research(demo): B1-B900 c")}, cleanRun(), nil),
		after("explicit-window-includes-later-commit-as-given", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), wide),
		after("explicit-window-excludes-later-commit", []commit{cm("00:30", "research(demo): B3 c")}, cleanRun(),
			[]string{"--corpus", "{{CORPUS}}", "--transcript", "{{TRANSCRIPT}}", "--until", ts("00:26")}),
		after("explicit-base-ref-window-is-respected", []commit{cm("00:30", "research(demo): B3 c")}, cleanRun(),
			[]string{"--corpus", "{{CORPUS}}", "--transcript", "{{TRANSCRIPT}}", "--base-ref", "HEAD~2"}),
		after("later-commit-with-stop-absent", []commit{cm("00:30", "research(demo): B3 c")}, jl(human(ts("00:00"), "go"), asst(ts("00:25"), "done")), nil),
		after("unwitnessed-with-qualified-stop", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), nil, "STUB_NEXT", stopClean+" [x: 1]"),
		after("unwitnessed-with-undeclared-queue", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), nil, "STUB_DEF", "x"),
		after("counted-outranks-unwitnessed-and-qualifier", []commit{cm("00:30", "research(demo): B3 c"), full("2026-06-02T00:00:00Z", "research(demo): B4 d")}, cleanRun(), nil, "STUB_NEXT", stopClean+" [x: 1]"),
		after("unwitnessed-with-open-queue-still-fails-on-queue", []commit{full("2026-06-02T00:00:00Z", "research(demo): B3 c")}, cleanRun(), nil, "STUB_DEF", "  campaign : pending=2 active=0"),
		after("later-commits-on-an-oos-default-window", []commit{cm("00:05", "research(demo): B0 early")}, cleanRun(), nil),
	}
}
