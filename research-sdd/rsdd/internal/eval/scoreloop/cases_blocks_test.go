package scoreloop

import "strings"

func one(subject string) []commit { return []commit{cm("00:10", subject), cm("00:20", subject)} }

// blockCases: which commit subjects count as block commits and with what weight (no transcript: git alone).
func blockCases() []scase {
	return []scase{
		{name: "blocks-two-plain", commits: twoBlocks},
		{name: "blocks-single", commits: []commit{cm("00:10", "research(demo): B1 gap-a")}},
		{name: "blocks-none-in-history", commits: []commit{cm("00:10", "chore: nothing"), cm("00:20", "docs(demo): B900 x")}},
		{name: "blocks-block-prefix", commits: one("block(demo-focus): B900 synthetic")},
		{name: "blocks-docs-prefix-excluded", commits: one("docs(demo-focus): B900 synthetic")},
		{name: "blocks-prefix-case-sensitive", commits: one("Research(demo): B1 x")},
		{name: "blocks-empty-scope-no-match", commits: one("research(): B1 x")},
		{name: "blocks-missing-space-after-colon", commits: one("research(demo):B1 x")},
		{name: "blocks-no-block-id", commits: one("research(demo): bootstrap focus")},
		{name: "blocks-preamble-before-id", commits: one("research(demo/wb): bootstrap focus + B1054 palette")},
		{name: "blocks-range-weight-3", commits: []commit{cm("00:10", "research(demo): B1161-B1163 SES10 x")}},
		{name: "blocks-range-weight-3-two-commits", commits: []commit{cm("00:10", "research(demo): B1-B3 x"), cm("00:20", "research(demo): B4 y")}},
		{name: "blocks-retro-citation-cut-by-paren", commits: []commit{cm("00:10", "research(demo): sec18 retro (B867-B891, MM1)")}},
		{name: "blocks-cut-by-em-dash", commits: []commit{cm("00:10", "research(demo): sec18 — closes B867-B891")}},
		{name: "blocks-cut-by-arrow", commits: []commit{cm("00:10", "research(demo): wrap → B5")}},
		{name: "blocks-id-before-delimiter-wins", commits: []commit{cm("00:10", "research(demo): B7 — B8-B20")}},
		{name: "blocks-first-id-only", commits: []commit{cm("00:10", "research(demo): B1 and B2 and B3")}},
		{name: "blocks-range-reversed-weight-1", commits: []commit{cm("00:10", "research(demo): B5-B3 x")}},
		{name: "blocks-range-equal-ends", commits: []commit{cm("00:10", "research(demo): B4-B4 x")}},
		{name: "blocks-range-at-cap-counts-in-full", commits: []commit{cm("00:10", "research(demo): B1-B51 x")}},
		{name: "blocks-range-over-cap-warns", commits: []commit{cm("00:10", "research(demo): B1-B52 x")}},
		{name: "blocks-range-huge-warns", commits: []commit{cm("00:10", "research(demo): B1000-B1200 SES99 x")}},
		{name: "blocks-range-leading-zeros-warn-keeps-text", commits: []commit{cm("00:10", "research(demo): B0007-B0300 x")}},
		{name: "blocks-range-leading-zeros-weight", commits: []commit{cm("00:10", "research(demo): B007-B009 x")}},
		{name: "blocks-cap-override-300", env: envOf("RSDD_BLOCK_RANGE_CAP", "300"), commits: []commit{cm("00:10", "research(demo): B1000-B1200 x")}},
		{name: "blocks-cap-override-zero", env: envOf("RSDD_BLOCK_RANGE_CAP", "0"), commits: []commit{cm("00:10", "research(demo): B1-B2 x"), cm("00:20", "research(demo): B9 y")}},
		{name: "blocks-cap-override-large-weight", env: envOf("RSDD_BLOCK_RANGE_CAP", "2000"), commits: []commit{cm("00:10", "research(demo): B1-B1500 x")}},
		{name: "blocks-cap-leading-zero-is-decimal", env: envOf("RSDD_BLOCK_RANGE_CAP", "010"), commits: []commit{cm("00:10", "research(demo): B1-B10 x")},
			intended: div(reasonOctal, "stdout", "stderr")},
		{name: "blocks-subject-with-tab-and-backslash", commits: []commit{cm("00:10", "research(demo): B1\tgap\\n x")}},
		{name: "blocks-long-subject", commits: []commit{cm("00:10", "research(demo): B1 "+strings.Repeat("x", 5000))}},
		{name: "blocks-commit-regex-override", env: envOf("RSDD_BLOCK_COMMIT_REGEX", `^(feat)\([^)]+\): (.*)$`), commits: []commit{cm("00:10", "feat(a): B1 x"), cm("00:20", "research(demo): B2 y")}},
		{name: "blocks-id-regex-override", env: envOf("RSDD_BLOCK_ID_REGEX", `#([0-9]+)(-#([0-9]+))?`), commits: []commit{cm("00:10", "research(demo): #4-#6 x")}},
		{name: "blocks-commit-regex-invalid", env: envOf("RSDD_BLOCK_COMMIT_REGEX", `^(research`), commits: twoBlocks, intended: div(reasonRegex, "stdout", "stderr", "exit")},
		{name: "blocks-id-regex-invalid", env: envOf("RSDD_BLOCK_ID_REGEX", `B([0-9]+`), commits: twoBlocks, intended: div(reasonRegex, "stdout", "stderr", "exit")},
		{name: "blocks-commit-regex-too-few-groups", env: envOf("RSDD_BLOCK_COMMIT_REGEX", `^research\(demo\): B1`), commits: twoBlocks, intended: div(reasonRegex, "stderr", "exit")},
		{name: "blocks-id-regex-no-groups", env: envOf("RSDD_BLOCK_ID_REGEX", `B[0-9]+`), commits: twoBlocks, intended: div(reasonRegex, "stderr", "exit")},
		{name: "blocks-question-regex-invalid", env: envOf("RSDD_QUESTION_REGEX", `(`), commits: twoBlocks, intended: div(reasonRegex, "stdout", "stderr", "exit")},
		{name: "blocks-stop-regex-invalid", env: envOf("RSDD_STOP_TOKEN_REGEX", `[`), commits: twoBlocks, intended: div(reasonRegex, "stdout", "stderr", "exit")},
	}
}
