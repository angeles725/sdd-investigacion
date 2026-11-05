package scoreloop

import "fmt"

// c1Cases: continued past block 1 (>= 2 block commits, weighted, with no operator turn between consecutive ones).
func c1Cases() []scase {
	fourBlocks := []commit{cm("00:10", "research(demo): B1 a"), cm("00:20", "research(demo): B2 b"), cm("00:30", "research(demo): B3 c"), cm("00:40", "research(demo): B4 d")}
	run := func(extra ...string) *string {
		lines := append([]string{human(ts("00:00"), "start")}, extra...)
		return jl(append(lines, asst(ts("00:45"), "end\nSTOP: campaign complete"))...)
	}
	noise := run(toolRes(ts("00:12")),
		`{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-06-01T00:13:00Z","message":{"content":"<task-notification>x</task-notification>"}}`,
		`{"type":"user","origin":{"kind":"peer"},"timestamp":"2026-06-01T00:14:00Z","message":{"content":"from a peer"}}`,
		`{"type":"user","origin":null,"timestamp":"2026-06-01T00:15:00Z","message":{"content":"<command-message>loop</command-message>"}}`,
		`{"type":"user","origin":{},"timestamp":"2026-06-01T00:16:00Z","message":{"content":"<local-command-stdout>x</local-command-stdout>"}}`)
	opAt := func(hm string) string { return human(ts(hm), "please continue") }
	in := func(name string, commits []commit, t *string) scase {
		return scase{name: "c1-" + name, commits: commits, transcript: t}
	}
	return []scase{
		in("pass-no-operator-between", fourBlocks, run()),
		in("noise-is-not-operator-input", fourBlocks, noise),
		in("operator-in-first-gap", fourBlocks, run(opAt("00:15"))),
		in("operator-in-middle-gap", fourBlocks, run(opAt("00:25"))),
		in("operator-in-last-gap", fourBlocks, run(opAt("00:35"))),
		in("operator-in-every-gap", fourBlocks, run(opAt("00:15"), opAt("00:25"), opAt("00:35"))),
		in("two-operators-in-one-gap-count-once", fourBlocks, run(opAt("00:15"), opAt("00:16"))),
		in("operator-exactly-at-commit-a", fourBlocks, run(opAt("00:20"))),
		in("operator-exactly-at-commit-b", fourBlocks, run(opAt("00:10"))),
		in("operator-before-first-commit", fourBlocks, run(opAt("00:05"))),
		in("operator-after-last-commit", fourBlocks, run(opAt("00:42"))),
		in("two-blocks-with-operator-between", twoBlocks, run(opAt("00:15"))),
		in("single-block-with-transcript", []commit{cm("00:10", "research(demo): B1 a")}, run()),
		in("range-weight-one-commit-passes", []commit{cm("00:10", "research(demo): B1-B3 a")}, run(opAt("00:15"))),
		in("range-then-commit-with-operator-between", []commit{cm("00:10", "research(demo): B1-B3 a"), cm("00:20", "research(demo): B4 b")}, run(opAt("00:15"))),
		in("same-epoch-commits-never-gap", []commit{cm("00:10", "research(demo): B1 a"), cm("00:10", "research(demo): B2 b")}, run(opAt("00:10"))),
		in("same-epoch-then-later-commit", []commit{cm("00:10", "research(demo): B1 a"), cm("00:10", "research(demo): B2 b"), cm("00:20", "research(demo): B3 c")}, run(opAt("00:15"))),
		in("no-block-commit-in-window", []commit{cm("00:10", "chore: a"), cm("00:20", "chore: b")}, run()),
		in("zero-blocks-with-unrecognised-shape", []commit{cm("00:10", "chore: a")}, jl(fmt.Sprintf(`{"type":"user","timestamp":%s}`, q(ts("00:00"))))),
		in("unrecognised-shape-outranks-single-block", []commit{cm("00:10", "research(demo): B1 a")}, jl(fmt.Sprintf(`{"type":"user","timestamp":%s}`, q(ts("00:00"))))),
		in("malformed-transcript-reports-count", twoBlocks, raw("not json at all\n")),
		in("tied-operator-and-assistant-times", twoBlocks, run(opAt("00:15"), asst(ts("00:15"), "x"))),
	}
}
