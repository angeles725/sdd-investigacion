package scoreloop

import "fmt"

// c3Cases: compaction (structural markers only): blocks before and after the first compaction event.
func c3Cases() []scase {
	repo := []commit{cm("00:05", "research(demo): B1 a"), cm("00:20", "research(demo): B2 b")}
	with := func(name string, extra ...string) scase {
		lines := append([]string{human(ts("00:00"), "go")}, extra...)
		return scase{name: "c3-" + name, commits: repo, transcript: jl(append(lines, asst(ts("00:30"), "end\nSTOP: campaign complete"))...)}
	}
	userFlag := func(at, flag string) string {
		return fmt.Sprintf(`{"type":"user","isCompactSummary":%s,"timestamp":%s,"message":{"content":"s"}}`, flag, q(ts(at)))
	}
	return []scase{
		with("none-is-the-best-outcome"),
		with("boundary-between-blocks", sysRec(ts("00:12"), "compact_boundary")),
		with("summary-between-blocks", summary(ts("00:12"))),
		with("boundary-before-every-block", sysRec(ts("00:02"), "compact_boundary")),
		with("boundary-after-every-block", sysRec(ts("00:25"), "compact_boundary")),
		with("boundary-exactly-at-a-block-counts-after", sysRec(ts("00:20"), "compact_boundary")),
		with("boundary-exactly-at-first-block-counts-after", sysRec(ts("00:05"), "compact_boundary")),
		with("first-compaction-wins", sysRec(ts("00:12"), "compact_boundary"), sysRec(ts("00:25"), "compact_boundary")),
		with("later-boundary-ignored-after-summary", summary(ts("00:12")), sysRec(ts("00:02"), "compact_boundary")),
		with("other-system-subtype-is-not-compaction", sysRec(ts("00:12"), "informational")),
		with("system-without-subtype", `{"type":"system","timestamp":"2026-06-01T00:12:00Z"}`),
		with("subtype-boundary-on-non-system-type", `{"type":"user","subtype":"compact_boundary","timestamp":"2026-06-01T00:12:00Z"}`),
		with("summary-flag-false", userFlag("00:12", "false")),
		with("summary-flag-null", userFlag("00:12", "null")),
		with("summary-flag-truthy-string", userFlag("00:12", `"yes"`)),
		with("summary-flag-zero-is-truthy", userFlag("00:12", "0")),
		with("summary-flag-on-assistant-record", `{"type":"assistant","isCompactSummary":true,"timestamp":"2026-06-01T00:12:00Z","message":{"content":"s"}}`),
		with("compaction-record-without-type-is-skipped", `{"subtype":"compact_boundary","isCompactSummary":true,"timestamp":"2026-06-01T00:12:00Z"}`),
		with("compaction-record-without-timestamp-is-skipped", `{"type":"system","subtype":"compact_boundary"}`),
		{name: "c3-out-of-span-block-degrades", commits: repo, transcript: jl(human(ts("00:10"), "go"), sysRec(ts("00:12"), "compact_boundary"), asst(ts("00:30"), "end")),
			args: []string{"--corpus", "{{CORPUS}}", "--transcript", "{{TRANSCRIPT}}", "--since", ts("00:00")}},
		{name: "c3-range-weights-before-and-after", commits: []commit{cm("00:05", "research(demo): B1-B3 a"), cm("00:20", "research(demo): B4-B5 b")},
			transcript: jl(human(ts("00:00"), "go"), sysRec(ts("00:12"), "compact_boundary"), asst(ts("00:30"), "end"))},
		{name: "c3-no-block-commits", commits: []commit{cm("00:05", "chore: a")}, transcript: jl(human(ts("00:00"), "go"), summary(ts("00:12")), asst(ts("00:30"), "end"))},
	}
}
