package show

import "strings"

// The S7 scenario table: full default-report runs whose verdict depends on the two sections slice S7 ports, the
// §8c campaign queue block (campaign_status_block and its readers) and the document-cycle outline. The groups are
// s7Campaign (the queue of one focus), s7Multi (several focuses, FOCUSES.md, --focus / --root) and s7Doc. The
// worlds, the frozen script and the replay are those of S6 (s6_harness_test.go); the clock is fixed at
// 2026-01-01T00:00:00Z on both sides.

func s7Scenarios() []s6Scenario {
	var scs []s6Scenario
	scs = append(scs, s7Campaign()...)
	scs = append(scs, s7Multi()...)
	scs = append(scs, s7Doc()...)
	return scs
}

// envWith adds envelope lines after the schema line of a state file.
func envWith(state string, lines ...string) string {
	return strings.Replace(state, "schema: research-state.v1\n", "schema: research-state.v1\n"+ln(lines...), 1)
}

const queueHdr = "| Entry | Seed | Kind | Convergence | Depth | State |\n|---|---|---|---|---|---|\n"

// qrow is a row of the campaign queue table.
func qrow(name, kind, state string) string {
	return "| " + name + " | seed | " + kind + " | conv | 1 | " + state + " |"
}

// queue is a "## Campaign queue" section holding the lines.
func queue(lines ...string) string { return "\n## Campaign queue\n\n" + ln(lines...) }

// withQueue is a state file with a pending gap, the envelope lines and the campaign queue section.
func withQueue(env []string, q string) string {
	return envWith(st6(1, q, row("high", "the root gap", "pending")), env...)
}

// cq is the one-state scenario of a queue section (env: extra envelope lines, flags: the command line).
func cq(name, want string, env []string, q string, flags ...string) s6Scenario {
	return os6(name, want, withQueue(env, q), nil, nil, flags...)
}

// tsOld is an hour before the fixed clock.
const tsOld = "last_iteration_ts: 2025-12-31T23:00:00Z"

// twoFocus is a corpus of the root state and the focus act, each with its own file content.
func twoFocus(root, act string, more files) files {
	return merge(files{"corpus/RESEARCH-STATE.md": root, "corpus/RESEARCH-STATE-act.md": act}, more)
}

// tsOnly is a state file with no queue and the given envelope lines.
func tsOnly(env ...string) string { return withQueue(env, "") }
