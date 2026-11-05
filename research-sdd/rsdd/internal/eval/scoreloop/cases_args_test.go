package scoreloop

// argCases: argument parsing, environment validation order, and the operational and degraded exits.
func argCases() []scase {
	c := "{{CORPUS}}"
	return []scase{
		{name: "args-none", args: []string{}, commits: twoBlocks},
		{name: "args-corpus-empty", args: []string{"--corpus", ""}, commits: twoBlocks},
		{name: "args-corpus-no-value", args: []string{"--corpus"}, commits: twoBlocks},
		{name: "args-transcript-no-value", args: []string{"--corpus", c, "--transcript"}, commits: twoBlocks},
		{name: "args-base-ref-no-value", args: []string{"--corpus", c, "--base-ref"}, commits: twoBlocks},
		{name: "args-since-no-value", args: []string{"--corpus", c, "--since"}, commits: twoBlocks},
		{name: "args-until-no-value", args: []string{"--corpus", c, "--until"}, commits: twoBlocks},
		{name: "args-help-short", args: []string{"-h"}, commits: twoBlocks},
		{name: "args-help-long", args: []string{"--corpus", c, "--help"}, commits: twoBlocks},
		{name: "args-unknown-flag", args: []string{"--corpus", c, "--bogus-flag"}, commits: twoBlocks},
		{name: "args-unknown-positional", args: []string{"stray"}, commits: twoBlocks},
		{name: "args-flag-value-looks-like-flag", args: []string{"--corpus", "--transcript"}, commits: twoBlocks},
		{name: "args-repeated-corpus-last-wins", args: []string{"--corpus", "{{S}}/none", "--corpus", c}, commits: twoBlocks},
		{name: "args-transcript-missing-file", args: []string{"--corpus", c, "--transcript", "{{S}}/nope.jsonl"}, commits: twoBlocks},
		{name: "args-transcript-is-directory", args: []string{"--corpus", c, "--transcript", "{{S}}"}, commits: twoBlocks},
		{name: "env-grace-not-integer", env: envOf("RSDD_C4_AFTER_STOP_GRACE", "abc"), commits: twoBlocks},
		{name: "env-grace-negative", env: envOf("RSDD_C4_AFTER_STOP_GRACE", "-1"), commits: twoBlocks},
		{name: "env-grace-empty-is-default", env: envOf("RSDD_C4_AFTER_STOP_GRACE", ""), commits: twoBlocks},
		{name: "env-range-cap-not-integer", env: envOf("RSDD_BLOCK_RANGE_CAP", "abc"), commits: twoBlocks},
		{name: "env-range-cap-empty-is-default", env: envOf("RSDD_BLOCK_RANGE_CAP", ""), commits: twoBlocks},
		{name: "env-grace-leading-zero-is-decimal", env: envOf("RSDD_C4_AFTER_STOP_GRACE", "010"), transcript: cleanRun(),
			commits: append(append([]commit(nil), twoBlocks...), cm("00:34", "research(demo): B3 c")), intended: div(reasonOctal, "stdout")},
		{name: "env-both-bad-grace-reported-first", env: envOf("RSDD_C4_AFTER_STOP_GRACE", "x", "RSDD_BLOCK_RANGE_CAP", "y"), commits: twoBlocks},
		{name: "env-bad-grace-outranks-absent-corpus", corpus: "absent", env: envOf("RSDD_C4_AFTER_STOP_GRACE", "x")},
		{name: "env-bad-grace-outranks-missing-transcript", args: []string{"--corpus", c, "--transcript", "{{S}}/nope"}, env: envOf("RSDD_C4_AFTER_STOP_GRACE", "x"), commits: twoBlocks},
		{name: "corpus-absent", corpus: "absent"},
		{name: "corpus-not-a-git-repo", corpus: "nogit"},
		{name: "corpus-is-a-file", corpus: "file"},
		{name: "corpus-repo-without-commits"},
		{name: "git-bad-base-ref", args: []string{"--corpus", c, "--base-ref", "not-a-real-ref"}, commits: twoBlocks},
		{name: "git-absent-degrades-whole-instrument", tools: "git", commits: twoBlocks},
		{name: "git-absent-with-transcript", transcript: cleanRun(), tools: "git", commits: twoBlocks},
	}
}
