package scoreloop

// jqCases: the RSDD_OPERATOR_INPUT_JQ and RSDD_COMPACT_JQ overrides (the only place jq is still needed) and the
// dependency-absent states (a PATH without jq, base64 or a -d capable date).
func jqCases() []scase {
	// A user record without origin that says "please continue" sits between the two blocks, and a system
	// record of another subtype: neither counts by default; both count under the overrides below.
	t := jl(human(ts("00:00"), "go"),
		`{"type":"user","timestamp":"2026-06-01T00:15:00Z","message":{"role":"user","content":"please continue"}}`,
		`{"type":"system","subtype":"other","timestamp":"2026-06-01T00:16:00Z"}`,
		asst(ts("00:25"), "end\nSTOP: campaign complete"))
	op := `.type=="user" and (.message.content=="please continue")`
	with := func(name string, env map[string]string) scase {
		return scase{name: name, commits: twoBlocks, transcript: t, env: env}
	}
	return []scase{
		with("jq-default-filters", nil),
		with("jq-operator-override", envOf("RSDD_OPERATOR_INPUT_JQ", op)),
		with("jq-compact-override", envOf("RSDD_COMPACT_JQ", `.type=="system"`)),
		with("jq-both-overrides", envOf("RSDD_OPERATOR_INPUT_JQ", op, "RSDD_COMPACT_JQ", `.type=="system"`)),
		with("jq-override-empty-output-drops-records", envOf("RSDD_OPERATOR_INPUT_JQ", "empty")),
		with("jq-override-invalid-program", envOf("RSDD_OPERATOR_INPUT_JQ", ".type ==")),
		with("jq-override-non-boolean-is-not-operator", envOf("RSDD_OPERATOR_INPUT_JQ", ".type")),
		with("jq-override-runtime-error", envOf("RSDD_COMPACT_JQ", `.message.content | ascii_downcase`)),
		with("jq-override-empty-value-is-default", envOf("RSDD_OPERATOR_INPUT_JQ", "")),
		{name: "jq-absent-with-override", commits: twoBlocks, transcript: t, tools: "jq", env: envOf("RSDD_COMPACT_JQ", `.type=="system"`)},
		{name: "jq-absent-without-override", commits: twoBlocks, transcript: t, tools: "jq", intended: div(reasonJQ, "stdout")},
		{name: "jq-absent-no-transcript-needs-nothing", commits: twoBlocks, tools: "jq"},
		{name: "base64-absent-with-transcript", commits: twoBlocks, transcript: t, tools: "base64", intended: div(reasonB64, "stdout")},
		{name: "base64-absent-no-transcript-needs-nothing", commits: twoBlocks, tools: "base64"},
		{name: "date-without-d-support", commits: twoBlocks, transcript: t, tools: "date", intended: div(reasonDate, "stdout", "stderr", "exit")},
	}
}
