package scoreloop

import "strings"

// c4QualifierCases: a QUALIFIED `--next` STOP is not a clean zero-open exhaustion (kit issue #1995).
func c4QualifierCases() []scase {
	stop := "done\nSTOP: campaign complete"
	next := func(name, line string, extra ...string) scase {
		return c4With("qual-"+name, stop, append([]string{"STUB_NEXT", line}, extra...)...)
	}
	return []scase{
		next("bare-form", stopClean),
		next("outline-fully-covered", "STOP | outline fully covered (3/4)"),
		next("outline-fully-covered-non-digits", "STOP | outline fully covered (a/b)"),
		next("issue-coverage-unverified", stopClean+" [issue-coverage: unverified]"),
		next("backlog-unreadable-rows", stopClean+" [backlog-unreadable: 2 rows]"),
		next("backlog-unreadable-unverified", stopClean+" [backlog-unreadable: unverified]"),
		next("two-brackets-joined", stopClean+" [a: 1] [b: 2]"),
		next("bracket-with-open-bracket-inside", stopClean+" [a [b] tail"),
		next("no-active-focus", "STOP | no active focus (no RESEARCH-STATE)"),
		next("no-active-focus-with-brackets", "STOP | no active focus (x) [issue-coverage: unverified] [b]"),
		next("no-active-focus-prefix-only", "STOP | no active focus"),
		next("unknown-form", "STOP | something else"),
		next("unknown-form-empty-rest", "STOP | "),
		next("unknown-form-without-pipe", "STOP x"),
		next("unknown-form-truncated-at-80", "STOP | "+strings.Repeat("abcdefghij", 12)),
		next("extra-lines-ignored", stopClean+"\nSTOP | second line"),
		next("exhausted-with-trailing-text", stopClean+" and more"),
		next("qualified-declared-non-empty-queue-fails", stopClean+" [x: 1]", "STUB_DEF", "  campaign : pending=1 active=1"),
		next("qualified-undeclared-queue-degrades", stopClean+" [x: 1]", "STUB_DEF", "  campaign : none (2 active focus(es), 0 with a queue)"),
		next("qualified-empty-queue-degrades", stopClean+" [x: 1]"),
		next("qualified-stop-absent-fails", stopClean+" [x: 1]"),
		c4With("qual-token-absent", "done", "STUB_NEXT", stopClean+" [x: 1]"),
		c4With("qual-undeclared-no-brackets", stop, "STUB_NEXT", "STOP | no active focus (y)", "STUB_DEF", "x"),
	}
}
