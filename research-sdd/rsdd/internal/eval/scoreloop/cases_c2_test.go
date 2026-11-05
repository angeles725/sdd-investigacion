package scoreloop

// c2Cases: questions asked (the FINAL PARAGRAPH of each final assistant message, not just the last line).
func c2Cases() []scase {
	final := func(name, text string, env ...string) scase {
		return scase{name: "c2-" + name, commits: twoBlocks, env: envOf(env...),
			transcript: jl(human(ts("00:00"), "go"), asst(ts("00:25"), text))}
	}
	finals := func(name string, lines ...string) scase {
		return scase{name: "c2-" + name, commits: twoBlocks, transcript: jl(append([]string{human(ts("00:00"), "go")}, lines...)...)}
	}
	return []scase{
		final("question-mark-ends", "done\nready for the next one?"),
		final("no-question", "done\nSTOP: campaign complete"),
		final("closing-bold", "done **really?**"),
		final("closing-italic", "done _really?_"),
		final("closing-code", "done `really?`"),
		final("closing-mixed-emphasis", "done *_`?*_`"),
		final("trailing-space-after-mark", "done really? "),
		final("question-mark-mid-line", "is this? yes it is"),
		final("shall-I", "I have more. shall I continue now"),
		final("should-I-capitalised", "Should I keep going"),
		final("do-you-want-upper", "DO YOU WANT more"),
		final("question-in-earlier-paragraph-not-counted", "why?\n\nall done"),
		final("question-in-earlier-line-of-final-paragraph", "why?\nall done"),
		final("spanish-pair", "listo\n¿seguimos con el siguiente bloque?"),
		final("spanish-pair-across-lines", "¿seguimos\ncon el siguiente bloque? sí"),
		final("spanish-opener-without-closer", "¿seguimos con el siguiente bloque"),
		final("closer-before-opener", "bloque? listo ¿"),
		final("two-openers-then-closer", "¿uno ¿dos?"),
		final("crlf-lines", "done\r\nready?\r\nmore"),
		final("crlf-final-question", "done\r\nready?\r\n"),
		final("trailing-blank-lines", "ready?\n\n\n"),
		final("blank-line-inside-final-paragraph-splits", "ready?\n\ndone"),
		final("whitespace-only-line-joins-paragraph", "ready?\n  \ndone"),
		final("whitespace-only-last-line", "ready?\n   "),
		final("empty-text", ""),
		final("only-newlines", "\n\n"),
		final("question-regex-override", "done\nmaybe", "RSDD_QUESTION_REGEX", "maybe"),
		final("question-regex-override-is-case-insensitive", "done\nMAYBE", "RSDD_QUESTION_REGEX", "maybe"),
		final("question-regex-override-replaces-default", "done\nready?", "RSDD_QUESTION_REGEX", "maybe"),
		final("question-regex-override-empty-is-default", "done\nready?", "RSDD_QUESTION_REGEX", ""),
		{name: "c2-content-as-plain-string", commits: twoBlocks, transcript: jl(human(ts("00:00"), "go"), asstStr(ts("00:25"), "ready?"))},
		{name: "c2-non-text-blocks-only", commits: twoBlocks, transcript: jl(human(ts("00:00"), "go"),
			`{"type":"assistant","timestamp":"2026-06-01T00:25:00Z","message":{"content":[{"type":"tool_use","name":"x"}]}}`)},
		finals("only-the-last-assistant-before-an-operator-counts", asst(ts("00:05"), "first?"), asst(ts("00:06"), "second"), human(ts("00:07"), "ok")),
		finals("every-final-counted", asst(ts("00:05"), "q1?"), human(ts("00:06"), "a"), asst(ts("00:07"), "fine"), human(ts("00:08"), "b"), asst(ts("00:09"), "q2?")),
		finals("first-match-epoch-is-reported", asst(ts("00:05"), "fine"), human(ts("00:06"), "a"), asst(ts("00:07"), "q?"), human(ts("00:08"), "b"), asst(ts("00:09"), "q2?")),
		finals("tool-results-do-not-flush-the-final", asst(ts("00:05"), "q?"), toolRes(ts("00:06")), asst(ts("00:07"), "fine")),
		finals("operator-turns-only-has-no-final-messages", human(ts("00:05"), "again")),
		finals("assistant-then-operator-at-same-second", asst(ts("00:05"), "q?"), human(ts("00:05"), "again")),
	}
}
