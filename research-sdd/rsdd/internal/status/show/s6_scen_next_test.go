package show

import "strings"

// The next-step group: the gap-centric walk across every focus (_ns_gap_run), its paused/stopped skip, the
// backlog-unreadable qualifier, the DEGRADED lines, the document-cycle stand-in, and the --focus / --root pick of
// the head state. Then the Stop hook line and the consistency footer.

func s6NextStep() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	const next = "  next step       : "
	unread := func(heading string, rows ...string) string {
		return strings.Replace(st4("", "0", 0, "", rows...), "## Gap-backlog (prioritized)", heading, 1)
	}
	u1 := "| 1 | numbered one | web | pending |"
	pending := func(name string, bsr string) string { return one(name, "pending", 1, bsr) }
	exhausted := func(name string) string { return one(name, "covered", 0, "0") }
	two := func(root, act string, more files) files {
		return merge(files{"corpus/RESEARCH-STATE.md": root, "corpus/RESEARCH-STATE-act.md": act}, more)
	}
	add(
		os6("n-single-focus-next", next+"NEXT | high | the root gap", pending("root", "0"), nil, nil),
		os6("n-single-focus-exhausted", next+stopLine, exhausted("root"), nil, nil),
		os6("n-tier-order", next+"NEXT | high | H1 high gap", st4("", "0", 3, "", row("low", "L1 low gap", "pending"), row("medium", "M1 medium gap", "pending"), row("high", "H1 high gap", "pending")), nil, nil),
		os6("n-blocked-name-is-skipped", next+"NEXT | medium | G2 second", blk(st4("", "0", 1, blockHdr+"- G1 first — needs: hardware\n", row("high", "G1 first", "pending"), row("medium", "G2 second", "pending"))), nil, nil),
		ws6("n-second-focus-has-the-gap", next+"NEXT | high | the act gap", two(exhausted("root"), pending("act", "0"), nil), nil),
		ws6("n-state-order-puts-the-focus-before-the-root", next+"NEXT | high | the act gap", two(pending("root", "0"), pending("act", "0"), nil), nil),
		ws6("n-all-focuses-exhausted", next+stopLine, two(exhausted("root"), exhausted("act"), nil), nil),
		ws6("n-stopped-focus-is-skipped-with-an-info-line", next+"NEXT | high | the root gap", two(pending("root", "0"), pending("act", "0"), files{"corpus/FOCUSES.md": focusRows("act", "stopped")}), nil),
		ws6("n-only-a-stopped-focus-has-gaps", next+"STOP | no active focus (1 declared stopped/paused in FOCUSES.md with open gaps)", two(exhausted("root"), pending("act", "0"), files{"corpus/FOCUSES.md": focusRows("act", "stopped")}), nil),
		ws6("n-only-a-paused-focus-has-gaps", next+"STOP | no active focus (1 declared stopped/paused", two(exhausted("root"), pending("act", "0"), files{"corpus/FOCUSES.md": focusRows("act", "paused")}), nil),
		ws6("n-stopped-focus-without-gaps-counts-nothing", next+stopLine, two(exhausted("root"), exhausted("act"), files{"corpus/FOCUSES.md": focusRows("act", "stopped")}), nil),
		ws6("n-two-skipped-focuses-are-counted", next+"STOP | no active focus (2 declared stopped/paused", merge(two(exhausted("root"), pending("act", "0"), nil),
			files{"corpus/RESEARCH-STATE-b.md": pending("b", "0"), "corpus/FOCUSES.md": focusRows("act", "stopped", "b", "paused")}), nil),
		ws6("n-open-focus-in-focuses-md-is-walked", next+"NEXT | high | the act gap", two(exhausted("root"), pending("act", "0"), files{"corpus/FOCUSES.md": focusRows("act", "open")}), nil),
		os6("n-backlog-unreadable-qualifier", next+stopLine+" [backlog-unreadable: 1 rows]", unread("## Gap backlog", u1), nil, nil),
		ws6("n-backlog-unreadable-sums-the-skipped-focuses", next+stopLine+" [backlog-unreadable: 1 rows]",
			two(exhausted("root"), unread("## Gap backlog", u1), files{"corpus/FOCUSES.md": focusRows("act", "stopped")}), nil),
		ws6("n-focus-flag-reports-that-focus-and-walks-all", next+"NEXT | high | the root gap", two(pending("root", "0"), exhausted("act"), nil), nil, "--focus", "act"),
		ws6("n-focus-flag-campaign-stand-in-sees-the-slug", "S6-STANDIN state=RESEARCH-STATE-act.md focus=act", two(pending("root", "0"), exhausted("act"), nil), nil, "--focus", "act"),
		ws6("n-root-flag-reports-the-root-state", next+"NEXT | high | the act gap", two(exhausted("root"), pending("act", "0"), nil), nil, "--root"),
		ws6("n-focus-flag-without-the-focus-bootstraps", "no RESEARCH-STATE-nope.md under", two(exhausted("root"), exhausted("act"), nil), nil, "--focus", "nope"),
	)
	unreadableStopped := ws6("n-stopped-focus-unreadable-is-unverified", next+stopLine+" [backlog-unreadable: unverified]", two(exhausted("root"), pending("act", "0"), files{"corpus/FOCUSES.md": focusRows("act", "stopped")}), nil)
	unreadableStopped.unreadable, unreadableStopped.needsUser = []string{"corpus/RESEARCH-STATE-act.md"}, true
	unreadableHead := os6("n-head-state-unreadable-degrades-the-next-step", next+"DEGRADED (blocked-rows derivation unreadable for RESEARCH-STATE.md", pending("root", "0"), nil, nil)
	unreadableHead.unreadable, unreadableHead.needsUser = []string{stateRel}, true
	add(unreadableStopped, unreadableHead)

	doc := func(mode, nxt string) map[string]string {
		env := map[string]string{"S6_DOC": mode}
		if nxt != "" {
			env["S6_DOC_NEXT"] = nxt
		}
		return env
	}
	add(
		os6("n-doc-outline-line-and-next", "  outline         : S6-STANDIN", pending("root", "0"), nil, doc("outline", "NEXT | outline #2 | Intro")),
		os6("n-doc-outline-next-is-final", next+"NEXT | outline #2 | Intro", pending("root", "0"), nil, doc("outline", "NEXT | outline #2 | Intro")),
		os6("n-doc-bootstrap-is-final", next+"BOOTSTRAP | seed the ## Outline first", exhausted("root"), nil, doc("outline", "BOOTSTRAP | seed the ## Outline first")),
		os6("n-doc-stop-yields-to-the-gap-next", next+"NEXT | high | the root gap", pending("root", "0"), nil, doc("outline", "STOP | outline fully covered (3/3)")),
		os6("n-doc-stop-replaces-the-gap-stop", next+"STOP | outline fully covered (3/3)", exhausted("root"), nil, doc("outline", "STOP | outline fully covered (3/3)")),
		ws6("n-doc-stop-replaces-the-root-flag-stop", next+"STOP | x", two(exhausted("root"), exhausted("act"), nil), doc("outline", "STOP | x"), "--root"),
		os6("n-doc-no-heading-says-so", "  outline         : (no ## Outline section — gap-centric verdicts kept)", pending("root", "0"), nil, doc("noheading", "")),
		os6("n-doc-no-heading-keeps-the-gap-walk", next+"NEXT | high | the root gap", pending("root", "0"), nil, doc("noheading", "")),
		os6("n-doc-outline-replaces-the-saturation-line", "  saturation      : n/a (method: document-cycle — gap saturation does not apply; the ## Outline decides)", st6(1, itTable(itHdr, it("1", "0")), row("high", "H", "pending")), nil, doc("outline", "")),
		os6("n-doc-no-heading-keeps-the-saturation-line", "  saturation      : insufficient history (1 iterations)", st6(1, itTable(itHdr, it("1", "0")), row("high", "H", "pending")), nil, doc("noheading", "")),
		os6("n-doc-none-prints-no-outline-line", "  saturation      : (no iteration history)", pending("root", "0"), nil, nil),
	)
	return scs
}

// A settings.json whose Stop hook runs retro-gate.sh.
const (
	hookWired = `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/kit/toolbelt/retro-gate.sh"}]}]}}`
	hookOther = `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}`
)

func s6Footer() []s6Scenario {
	var scs []s6Scenario
	base := st6(1, "", row("high", "H1", "pending"))
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	hook := func(name, want string, f files) {
		add(os6(name, want, base, f, nil))
	}
	hook("o-hook-absent-settings", "  Stop hook       : absent-settings (checked: <ROOT>/corpus)", nil)
	hook("o-hook-wired", "  Stop hook       : wired (checked: <ROOT>/corpus)", files{"corpus/.claude/settings.json": hookWired})
	hook("o-hook-unwired", "  Stop hook       : unwired (checked: <ROOT>/corpus)", files{"corpus/.claude/settings.json": hookOther})
	hook("o-hook-settings-not-json", "  Stop hook       : ", files{"corpus/.claude/settings.json": "{not json"})
	hook("o-hook-empty-object", "  Stop hook       : unwired (checked: <ROOT>/corpus)", files{"corpus/.claude/settings.json": "{}"})
	rel := os6("o-hook-checked-path-is-absolute-for-a-relative-target", "(checked: <ROOT>/corpus)", base, nil, nil)
	rel.runs = [][]string{{"corpus"}}
	dots := os6("o-hook-checked-path-is-normalised", "(checked: <ROOT>/corpus)", base, nil, nil)
	dots.runs = [][]string{{"./corpus/../corpus/"}}
	add(rel, dots)
	foot := func(name, want string, sp files) {
		add(os6(name, want, base, sp, nil))
	}
	const hdr = "  --- consistency (verify-state.sh) ---\n"
	foot("f-no-output", hdr, nil)
	foot("f-summary-line", hdr+"  summary: 12 passed, 0 failed", spec("v.out", "summary: 12 passed, 0 failed"))
	foot("f-keeps-fail-warn-ok-and-summary-lines", "  FAIL: a\n  WARN: b\n  ok  c\n  summary", spec("v.out", "FAIL: a\nnoise\nWARN: b\nok  c\nsummary x\nmore noise"))
	foot("f-drops-other-lines", hdr, spec("v.out", "alpha\nbeta\nOK upper\nwarn lower\nfail lower\nok"))
	foot("f-ok-needs-its-trailing-space", "  ok x", spec("v.out", "ok\nok x\nbook\nlook there"))
	foot("f-substring-matches-count", "  a FAILURE here\n  summary in the middle", spec("v.out", "a FAILURE here\nnot a SUMMARY\nsummary in the middle\nSUMMARY upper"))
	foot("f-stderr-is-merged", "  ok  firstWARN: from stderr", spec("v.out", "ok  first", "v.err", "WARN: from stderr"))
	foot("f-nonzero-exit-never-changes-ours", "  FAIL: stale mirror", spec("v.out", "FAIL: stale mirror", "v.rc", "1"))
	foot("f-exit-two-too", "  FAIL: bad args", spec("v.out", "FAIL: bad args", "v.rc", "2"))
	foot("f-last-line-without-newline", "  summary: done", files{"spec/v.out": "FAIL: x\nsummary: done"})
	foot("f-blank-and-indented-lines", "  \tFAIL: indented", files{"spec/v.out": "\n\n\tFAIL: indented\n\n"})
	foot("f-argument-is-the-corpus", hdr, nil)
	sub := ws6("f-argument-is-the-corpus-of-a-subdirectory", hdr, files{"corpus/sub/RESEARCH-STATE.md": base}, nil)
	add(sub)
	return scs
}
