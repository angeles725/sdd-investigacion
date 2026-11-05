package scoreloop

const (
	queueDrained = "  campaign        : pending=0 active=0 done=2 bound-stopped=0 rejected=0"
	stopClean    = "STOP | read-only-investigable exhausted (0)"
)

// c4With is a clean two-block run whose final message is text, scored against a stub configured by env.
func c4With(name, text string, env ...string) scase {
	return scase{name: "c4-" + name, commits: twoBlocks, env: envOf(env...),
		transcript: jl(human(ts("00:00"), "go"), asst(ts("00:25"), text))}
}

// c4Cases: STOP honored: the STOP token, the status script's verdicts, the campaign queue.
func c4Cases() []scase {
	stop := "done\nSTOP: campaign complete"
	return []scase{
		c4With("pass", stop),
		c4With("stop-bold-wrapper", "done\n**STOP:** campaign complete"),
		c4With("stop-blockquote-wrapper", "done\n> STOP: campaign complete"),
		c4With("stop-code-wrapper", "done\n`STOP: campaign complete`"),
		c4With("stop-underscore-and-spaces-wrapper", "done\n _ STOP: campaign complete"),
		c4With("stop-trailing-blank-lines", "done\nSTOP: campaign complete\n\n"),
		c4With("stop-absent", "done\nall good"),
		c4With("stop-lowercase-is-absent", "done\nstop: campaign complete"),
		c4With("stop-not-at-line-start", "done\nplease STOP: now"),
		c4With("stop-only-in-earlier-line", "STOP: campaign complete\nbye"),
		c4With("stop-in-earlier-paragraph", "STOP: campaign complete\n\nbye"),
		c4With("stop-regex-override", "done\nDONE: all", "RSDD_STOP_TOKEN_REGEX", "^DONE:"),
		c4With("stop-regex-override-replaces-default", stop, "RSDD_STOP_TOKEN_REGEX", "^DONE:"),
		c4With("stop-regex-override-empty-is-default", stop, "RSDD_STOP_TOKEN_REGEX", ""),
		c4With("next-not-stop", stop, "STUB_NEXT", "CONTINUE | 3 open"),
		c4With("next-stop-without-space", stop, "STUB_NEXT", "STOP"),
		c4With("next-stop-not-first-line-is-not-stop", stop, "STUB_NEXT", "info\nSTOP | read-only-investigable exhausted (0)"),
		c4With("next-stale", stop, "STUB_NEXT", "STALE | state is inconsistent"),
		c4With("next-stale-on-later-line-is-not-stale", stop, "STUB_NEXT", "x\nSTALE | y"),
		c4With("status-default-fails", stop, "STUB_RC_DEF", "1", "STUB_ERR", "synthetic operational failure"),
		c4With("status-next-fails", stop, "STUB_RC_NEXT", "3"),
		c4With("status-both-fail-stderr-collected", stop, "STUB_RC_DEF", "2", "STUB_RC_NEXT", "2", "STUB_ERR", "boom"),
		c4With("status-stderr-first-line-truncated-at-200", stop, "STUB_RC_DEF", "1", "STUB_ERR", longLine(250)),
		c4With("status-stderr-first-line-empty", stop, "STUB_RC_DEF", "1", "STUB_ERR", "\nsecond line"),
		c4With("status-warn-stderr-does-not-leak", stop, "STUB_ERR", "WARN: something odd"),
		c4With("status-script-missing", stop, "RSDD_STATUS_SCRIPT", "{{S}}/no-such-status.sh"),
		c4With("status-script-is-a-directory", stop, "RSDD_STATUS_SCRIPT", "{{S}}"),
		withToolbelt(c4With("status-script-override-empty-uses-sibling", stop, "RSDD_STATUS_SCRIPT", ""), true),
		withToolbelt(c4With("status-default-path-missing", stop, "RSDD_STATUS_SCRIPT", ""), false),
		c4With("queue-undeclared-none-line", stop, "STUB_DEF", "  campaign        : none (2 active focus(es), 0 with a queue)"),
		c4With("queue-no-campaign-line", stop, "STUB_DEF", "something else entirely"),
		c4With("queue-non-empty-pending", stop, "STUB_DEF", "  campaign        : pending=1 active=0"),
		c4With("queue-non-empty-active", stop, "STUB_DEF", "  campaign        : pending=0 active=2"),
		c4With("queue-pending-without-active-is-undeclared", stop, "STUB_DEF", "  campaign        : pending=0"),
		c4With("queue-active-without-pending-is-undeclared", stop, "STUB_DEF", "  campaign        : active=0"),
		c4With("queue-multifocus-drained", stop, "STUB_DEF", "  campaign[alpha] : pending=0 active=0\n  campaign[beta]  : pending=0 active=0"),
		c4With("queue-multifocus-mixed", stop, "STUB_DEF", "  campaign[alpha] : pending=0 active=0\n  campaign[beta]  : pending=2 active=1"),
		c4With("queue-multifocus-open-first", stop, "STUB_DEF", "  campaign[alpha] : pending=2 active=1\n  campaign[beta]  : pending=0 active=0"),
		c4With("queue-labelled-line-without-counts-then-drained", stop, "STUB_DEF", "  campaign[alpha] : none\n  campaign[beta]  : pending=0 active=0"),
		c4With("queue-repeated-counts-on-one-line", stop, "STUB_DEF", "  campaign : pending=0 pending=3 active=0"),
		c4With("queue-repeated-zero-counts-on-one-line", stop, "STUB_DEF", "  campaign : pending=0 active=0 pending=0"),
		c4With("queue-no-spaces-around-colon", stop, "STUB_DEF", "campaign:pending=0 active=0"),
		c4With("queue-multi-digit-counts", stop, "STUB_DEF", "  campaign : pending=00 active=0"),
		c4With("queue-word-before-campaign", stop, "STUB_DEF", "recampaign : pending=0 active=0"),
		c4With("queue-bracket-label-with-spaces", stop, "STUB_DEF", "  campaign[a b] : pending=0 active=0"),
		c4With("queue-drained-but-stop-absent", "done", "STUB_DEF", queueDrained),
		c4With("queue-non-empty-stop-absent-next-not-stop", "done", "STUB_NEXT", "CONTINUE | 1", "STUB_DEF", "  campaign : pending=4 active=0"),
		c4With("final-message-question-and-stop", "STOP: campaign complete?"),
	}
}

func longLine(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte('a' + i%26)
	}
	return string(b)
}

// withToolbelt gives the case a --toolbelt directory; sibling also installs the stub there as the default script.
func withToolbelt(c scase, sibling bool) scase {
	c.toolbelt, c.sibling = true, sibling
	return c
}
