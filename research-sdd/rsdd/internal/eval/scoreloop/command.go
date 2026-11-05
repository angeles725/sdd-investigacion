// Package scoreloop is `rsdd eval score-loop`: the eval scorer of a research-sdd loop run (kit issue #993),
// ported from toolbelt/score-loop-transcript.sh. It scores a corpus (a git repository) and, optionally, a session
// transcript (JSONL) on four criteria (C1 continued past block 1, C2 questions asked, C3 compaction, C4 STOP
// honored). Where to change what: args.go (flags), config.go (env overrides, defaults), record.go and
// transcript.go (transcript parsing), window.go and blocks.go (git window, block commits), c1.go to c4*.go (one
// criterion each), results.go (output), run.go (composition).
package scoreloop

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Command is the `rsdd eval score-loop` table entry. The legacy script prints its own lowercase "degraded:" line on
// exit 3, so PlainExit3 keeps the generic DEGRADED: line off stderr (byte parity).
var Command = cli.Command{
	Name:       "score-loop",
	Group:      "eval",
	Summary:    "score a loop run: C1 continued past block 1, C2 questions, C3 compaction, C4 STOP honored (port of score-loop-transcript.sh)",
	Run:        Run,
	PlainExit3: true,
}
