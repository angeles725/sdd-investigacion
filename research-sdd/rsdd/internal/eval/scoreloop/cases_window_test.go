package scoreloop

// windowCases: the git window (--base-ref, --since, --until, the default transcript-span window).
func windowCases() []scase {
	c := "{{CORPUS}}"
	spanRepo := []commit{cm("00:05", "research(demo): B1 gap-a"), cm("00:15", "research(demo): B2 gap-b")}
	spanT := jl(human(ts("00:10"), "go"), asst(ts("00:20"), "done\nSTOP: campaign complete"))
	return []scase{
		{name: "window-base-ref-last-commit", args: []string{"--corpus", c, "--base-ref", "HEAD~1"}, commits: threeBlocks},
		{name: "window-base-ref-two-back", args: []string{"--corpus", c, "--base-ref", "HEAD~2"}, commits: threeBlocks},
		{name: "window-base-ref-head-is-empty", args: []string{"--corpus", c, "--base-ref", "HEAD"}, commits: threeBlocks},
		{name: "window-since", args: []string{"--corpus", c, "--since", ts("00:15")}, commits: threeBlocks},
		{name: "window-until", args: []string{"--corpus", c, "--until", ts("00:25")}, commits: threeBlocks},
		{name: "window-since-and-until", args: []string{"--corpus", c, "--since", ts("00:15"), "--until", ts("00:25")}, commits: threeBlocks},
		{name: "window-base-ref-and-since", args: []string{"--corpus", c, "--base-ref", "HEAD~2", "--since", ts("00:25")}, commits: threeBlocks},
		{name: "window-empty-counts-examined", args: []string{"--corpus", c, "--since", "2027-01-01T00:00:00Z"}, commits: threeBlocks},
		{name: "window-examined-counts-non-block-commits", commits: []commit{cm("00:10", "chore: a"), cm("00:15", "research(demo): B1 x"), cm("00:20", "fix: b")}},
		{name: "window-commit-with-offset-date", commits: []commit{{"2026-06-01T02:10:00+02:00", "research(demo): B1 x"}, {"2026-05-31T23:20:00-01:00", "research(demo): B2 y"}}},
		{name: "window-default-is-transcript-span", commits: spanRepo, transcript: spanT},
		{name: "window-explicit-since-widens-to-out-of-span", args: []string{"--corpus", c, "--transcript", "{{TRANSCRIPT}}", "--since", ts("00:00")}, commits: spanRepo, transcript: spanT},
		{name: "window-explicit-until-keeps-span-lower-bound-off", args: []string{"--corpus", c, "--transcript", "{{TRANSCRIPT}}", "--until", ts("00:30")}, commits: spanRepo, transcript: spanT},
		{name: "window-explicit-base-ref-with-transcript", args: []string{"--corpus", c, "--transcript", "{{TRANSCRIPT}}", "--base-ref", "HEAD~1"}, commits: spanRepo, transcript: spanT},
		{name: "window-default-empty-for-transcript-span", commits: []commit{cm("01:00", "research(demo): B1 x"), cm("01:10", "research(demo): B2 y")}, transcript: spanT},
	}
}

// timeCases: the timestamp forms a transcript may carry (date -d accepted all of these; the Go parser keeps them).
func timeCases() []scase {
	form := func(name, first, mid, last string) scase {
		return scase{name: "time-" + name, commits: []commit{cm("00:10", "research(demo): B1 x"), cm("00:20", "research(demo): B2 y")},
			transcript: jl(human(first, "go"), asst(mid, "work"), asst(last, "end\nSTOP: campaign complete"))}
	}
	return []scase{
		form("rfc3339-z", ts("00:00"), ts("00:12"), ts("00:25")),
		form("fractional-seconds", day+"00:00:00.250Z", day+"00:12:00.5Z", day+"00:25:00.999999999Z"),
		form("offset-colon", "2026-06-01T02:00:00+02:00", "2026-06-01T02:12:00+02:00", "2026-06-01T02:25:00+02:00"),
		form("offset-no-colon", "2026-06-01T02:00:00+0200", "2026-06-01T02:12:00+0200", "2026-06-01T02:25:00+0200"),
		form("offset-hours-only", "2026-06-01T02:00:00+02", "2026-06-01T02:12:00+02", "2026-06-01T02:25:00+02"),
		form("space-separator", "2026-06-01 00:00:00Z", "2026-06-01 00:12:00Z", "2026-06-01 00:25:00Z"),
		form("zoneless-is-utc", "2026-06-01T00:00:00", "2026-06-01T00:12:00", "2026-06-01T00:25:00"),
		form("zoneless-space", "2026-06-01 00:00:00", "2026-06-01 00:12:00", "2026-06-01 00:25:00"),
		form("no-seconds", "2026-06-01T00:00", "2026-06-01T00:12", "2026-06-01T00:25"),
		form("unpadded", "2026-6-1T0:00:00Z", "2026-6-1T0:12:00Z", "2026-6-1T0:25:00Z"),
		form("lowercase-t-and-z", "2026-06-01t00:00:00z", "2026-06-01t00:12:00z", "2026-06-01t00:25:00z"),
		withDiv(form("mixed-offsets-in-order", ts("00:00"), "2026-06-01T02:12:00+02:00", ts("00:25")), div(reasonSort, "stdout")),
		form("unparsable-middle-skipped", ts("00:00"), "2026-13-45T99:99:99Z", ts("00:25")),
		form("garbage-text-skipped", ts("00:00"), "not a date", ts("00:25")),
		form("invalid-hour-24", ts("00:00"), "2026-06-01T24:00:00Z", ts("00:25")),
		{name: "time-order-fraction-vs-whole-second", intended: div(reasonSort, "stdout"), commits: twoBlocks, transcript: jl(human(ts("00:00"), "go"),
			asst("2026-06-01T00:10:00Z", "first?"), asst("2026-06-01T00:10:00.5Z", "second\nSTOP: campaign complete"))},
		{name: "time-order-offsets-sort-by-instant", intended: div(reasonSort, "stdout"), commits: twoBlocks, transcript: jl(human(ts("00:00"), "go"),
			asst("2026-06-01T02:20:00+02:00", "question?"), asst(ts("00:25"), "STOP: campaign complete"))},
	}
}
