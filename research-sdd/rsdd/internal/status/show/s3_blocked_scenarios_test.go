package show

// blocked_open_count (lib/blocked-rows.sh) as the --sync-state pre-pass calls it: the standard blocked sections and
// the multi-line `## Child gaps surfaced at close` entries with their closed markers and negation window. One
// scenario per state file, one op: the integer on stdout, or the typed rc 2 line for an unreadable file. The
// reference is the LIVE library (it is sourced, not frozen: the port must agree with it).

const goldenBlockedOpen = goldenS2Dir + "s3-blocked.golden"

const childHead = "## Child gaps surfaced at close"

func bo(name, state string) s2Scenario {
	return s2Scenario{name: "bo-" + name, state: state, ops: []op{o("blocked_open_count", "{ROOT}/"+stateRel)}}
}

// childGaps is a state file whose only section is the child-gap one.
func childGaps(name string, lines ...string) s2Scenario {
	return bo("child-"+name, ln(append([]string{"# S", "", childHead}, lines...)...))
}

func blockedSection(name, heading string, lines ...string) s2Scenario {
	return bo("std-"+name, ln(append([]string{"# S", "", heading}, lines...)...))
}

func blockedOpenScenarios() []s2Scenario {
	scs := []s2Scenario{
		bo("empty-file", ""),
		bo("no-sections", ln("# S", "- a needs: x", "text")),
		{name: "bo-unreadable", state: "# S\n", unreadable: true, ops: []op{o("blocked_open_count", "{ROOT}/"+stateRel)}},
		bo("crlf-lines", "## Blocked gaps\r\n- a needs: x\r\n\r\n"+childHead+"\r\n- C1 needs: y\r\n"),

		// standard sections
		blockedSection("bullet-needs", "## Blocked gaps", "- a needs: x", "-  b NEEDS: y", "- none", "text without it"),
		blockedSection("bold-prose-form", "## Blocked gaps", "text **needs:** x", "**NEEDS:** y", "  **needs:**"),
		blockedSection("bold-prose-needs-a-colon-and-stars", "## Blocked gaps", "**needs** x", "*needs:* y", "**needs:*"),
		blockedSection("dash-without-space-is-not-a-bullet", "## Blocked gaps", "-needs: nospace", "-a needs: x"),
		blockedSection("dash-space-then-needs", "## Blocked gaps", "- needs:", "-\tx needs: y", "  \t- z needs: w"),
		blockedSection("needs-before-the-dash-only", "## Blocked gaps", "needs: x - y", "* a needs: x"),
		blockedSection("needs-without-colon", "## Blocked gaps", "- a needs x", "- b need: y"),
		blockedSection("non-investigable", "## Non-investigable gaps", "- a needs: x", "- b needs: y"),
		blockedSection("blocked-slash", "## Blocked / parked", "- a needs: x"),
		blockedSection("heading-with-suffix", "## Blocked gaps (hardware)", "- a needs: x"),
		blockedSection("blocked-alone-is-no-heading", "## Blocked", "- a needs: x"),
		blockedSection("third-level-heading-is-no-heading", "### Blocked gaps", "- a needs: x"),
		blockedSection("heading-must-start-the-line", " ## Blocked gaps", "- a needs: x"),
		bo("std-three-headings-add-up", ln("## Blocked gaps", "- a needs: x", "## Non-investigable gaps", "- b needs: y", "## Blocked / z", "- c needs: z", "- d needs: z")),
		bo("std-same-heading-twice", ln("## Blocked gaps", "- a needs: x", "## Notes", "- n needs: no", "## Blocked gaps", "- b needs: y")),
		bo("std-section-ends-at-the-next-heading", ln("## Blocked gaps", "- a needs: x", "## Other", "- b needs: y")),
		bo("std-section-ends-only-at-two-hash-space", ln("## Blocked gaps", "- a needs: x", "###", "- b needs: y", "##x", "- c needs: z", "#", "- d needs: w")),
		bo("std-sections-plus-child-gaps", ln("## Blocked gaps", "- a needs: x", childHead, "- C1 needs: y", "  needs: z", "- C2 q")),

		// child gaps: the shapes of an entry
		childGaps("bullet-needs", "- C1 needs: hw"),
		childGaps("no-needs", "- C1 something", "- C2 other"),
		childGaps("needs-in-the-continuation", "- C1 x", "  needs: hw"),
		childGaps("needs-after-a-blank-line-is-not-the-entry", "- C1 x", "", "  needs: hw"),
		childGaps("needs-on-the-bullet-and-the-continuation-counts-once", "- C1 needs: a", "  needs: b", "  needs: c"),
		childGaps("two-entries", "- C1 needs: a", "- C2 needs: b", "- C3 c"),
		childGaps("continuation-before-any-bullet", "text needs: x", "- C1 y"),
		childGaps("second-entry-takes-over-the-continuation", "- C1 x", "- C2 y", "  needs: z"),
		childGaps("upper-case-needs", "- C1 NEEDS: x", "- C2 x", "  Needs: y"),
		childGaps("tab-after-the-dash", "-\tC1 needs: x", "  -\tC2 y", "\t\tneeds: z"),
		childGaps("no-space-after-the-dash-is-a-continuation", "- C1 x", "-C2 needs: y"),
		childGaps("indented-bullet", "   - C1 needs: x"),
		childGaps("blank-line-with-blanks-resets", "- C1 x", "   \t ", "  needs: y"),
		childGaps("heading-with-suffix", "- C1 needs: x"),
		bo("child-heading-suffix-matches", ln("## Child gaps surfaced at close (round 2)", "- C1 needs: x")),
		bo("child-heading-twice", ln(childHead, "- C1 needs: x", "## Mid", childHead, "- C2 needs: y")),
		bo("child-section-ends-at-heading", ln(childHead, "- C1 x", "## Mid", "  needs: y")),

		// child gaps: closed markers
		childGaps("strike-whole-entry", "- ~~C1~~ needs: x"),
		childGaps("strike-bold-opens-the-entry", "- **~~C1 needs: x"),
		childGaps("strike-mid-line-closes-nothing", "- C1 ~~old~~ needs: x"),
		childGaps("strike-after-a-space", "- ~~ C1 needs: x"),
		childGaps("strike-with-two-spaces", "-  ~~C1 needs: x"),
		childGaps("strike-single-tilde", "- ~C1 needs: x"),
		childGaps("strike-after-one-star", "- *~~C1 needs: x"),
		childGaps("strike-closes-continuation-needs", "- ~~C1~~", "  needs: x"),
		childGaps("tick", "- C1 ✅ needs: x"),
		childGaps("tick-first", "- ✅ C1 needs: x"),
		childGaps("tick-on-the-continuation-does-not-close", "- C1 x", "  ✅ needs: y"),
		childGaps("closed-word", "- C1 CLOSED needs: x"),
		childGaps("closed-word-starts-the-entry", "- CLOSED needs: x"),
		childGaps("closed-word-ends-the-line", "- C1 needs: x CLOSED"),
		childGaps("closed-lowercase-is-no-marker", "- C1 closed needs: x"),
		childGaps("closed-mixed-case-is-no-marker", "- C1 Closed needs: x"),
		childGaps("closed-inside-a-hyphenated-word", "- CLOSED-LOOP needs: x"),
		childGaps("closed-inside-a-longer-word", "- ENCLOSED needs: x"),
		childGaps("closed-doubled", "- CLOSEDCLOSED needs: x"),
		childGaps("closed-then-closed-separately", "- CLOSEDCLOSED CLOSED needs: x"),
		childGaps("closed-with-underscore-neighbour", "- X_CLOSED needs: x"),
		childGaps("closed-with-underscore-after", "- CLOSED_X needs: x"),
		childGaps("closed-with-hyphen-before", "- X-CLOSED needs: x"),
		childGaps("closed-with-digit-neighbour", "- 1CLOSED needs: x"),
		childGaps("closed-with-punctuation-neighbours", "- (CLOSED) needs: x", "- CLOSED. needs: y", "- [CLOSED] needs: z"),
		childGaps("closed-after-a-non-ascii-letter", "- \xc3\xa9CLOSED needs: x"),
		childGaps("cerrado-word", "- C1 CERRADO needs: x"),
		childGaps("cerrado-lowercase-is-no-marker", "- C1 cerrado needs: x"),
		childGaps("cerrado-inside-a-longer-word", "- CERRADOS needs: x"),
		childGaps("bracket-closed", "- C1 [closed] needs: x"),
		childGaps("bracket-closed-mixed-case", "- C1 [CLOSED] needs: x", "- C2 [Cerrado] needs: y", "- C3 [cErRaDo] needs: z"),
		childGaps("bracket-with-spaces-is-no-marker", "- C1 [ closed ] needs: x"),
		childGaps("bracket-closed-on-the-continuation-does-not-close", "- C1 x", "  [closed] needs: y"),
		childGaps("closed-bullet-then-continuation-needs", "- C1 CLOSED", "  needs: x"),
		childGaps("closed-bullet-then-open-bullet", "- C1 CLOSED needs: a", "- C2 needs: b"),

		// child gaps: the negation window
		childGaps("not-closed", "- C1 NOT CLOSED needs: x"),
		childGaps("not-yet-closed", "- C1 NOT YET CLOSED needs: x"),
		childGaps("not-yet-closed-lowercase-fillers", "- C1 NOT yet CLOSED needs: x"),
		childGaps("lowercase-not-yet-closed", "- C1 not yet CLOSED needs: x"),
		childGaps("mixed-case-not-adjacent", "- C1 Not CLOSED needs: x", "- C2 nOt CLOSED needs: y"),
		childGaps("no-longer-closed", "- C1 no longer CLOSED needs: x"),
		childGaps("no-and-never", "- C1 NO CLOSED needs: x", "- C2 NEVER CLOSED needs: y", "- C3 never CLOSED needs: z", "- C4 No CLOSED needs: w"),
		childGaps("lowercase-no-then-a-word-is-not-negated", "- C1 no repro — CLOSED needs: x"),
		childGaps("lowercase-not-then-a-word-is-not-negated", "- C1 not needed, CLOSED needs: x"),
		childGaps("lowercase-no-reproducible", "- C1 no reproducible — CLOSED needs: x"),
		childGaps("uppercase-not-two-words-back", "- C1 NOT A CLOSED needs: x"),
		childGaps("uppercase-not-three-words-back", "- C1 NOT A B CLOSED needs: x"),
		childGaps("lowercase-not-two-words-back-is-not-negated", "- C1 not x CLOSED needs: y"),
		childGaps("uppercase-no-two-words-back-after-a-filler", "- C1 NO YET CLOSED needs: x", "- C2 NO LONGER CLOSED needs: y"),
		childGaps("filler-alone-does-not-negate", "- C1 YET CLOSED needs: x", "- C2 LONGER CLOSED needs: y"),
		childGaps("filler-then-lowercase-not-keeps-any-case", "- C1 not YET longer CLOSED needs: x"),
		childGaps("filler-chain-then-not", "- C1 not YET LONGER CLOSED needs: x"),
		childGaps("regression-no-dash-closed", "- C1 regression? no — CLOSED needs: x"),
		childGaps("not-with-punctuation-between", "- C1 NOT — CLOSED needs: x", "- C2 NOT, CLOSED needs: y", "- C3 NOT: CLOSED needs: z"),
		childGaps("not-with-a-bare-dash-run-between", "- C1 NOT YET - CLOSED needs: x", "- C2 NOT -- CLOSED needs: y", "- C3 NOT __ CLOSED needs: z"),
		childGaps("not-glued-to-a-hyphen-is-another-word", "- C1 X-NO CLOSED needs: x", "- C2 NO-X CLOSED needs: y"),
		childGaps("not-glued-to-an-underscore", "- C1 NO_X CLOSED needs: x"),
		childGaps("not-after-a-non-ascii-letter", "- C1 \xc3\xa9NOT CLOSED needs: x"),
		childGaps("not-as-part-of-a-word", "- C1 KNOT CLOSED needs: x", "- C2 NOTE CLOSED needs: y", "- C3 NOW CLOSED needs: z"),
		childGaps("not-closed-then-closed", "- C1 NOT CLOSED but CLOSED needs: x"),
		childGaps("closed-then-not-closed", "- C1 CLOSED NOT CLOSED needs: x"),
		childGaps("two-negated-markers", "- C1 NOT CLOSED, NEVER CLOSED needs: x"),
		childGaps("cerrado-negated", "- C1 NO CERRADO needs: x", "- C2 not yet CERRADO needs: y"),
		childGaps("negated-closed-but-cerrado-closes", "- C1 NOT CLOSED CERRADO needs: x"),
		childGaps("negated-closed-but-bracket-closes", "- C1 NOT CLOSED [closed] needs: x"),
		childGaps("negated-closed-but-tick-closes", "- C1 NOT CLOSED ✅ needs: x"),
		childGaps("negation-on-an-earlier-line-does-not-carry", "- C1 NOT", "  CLOSED needs: x"),
		childGaps("window-at-the-start-of-the-line", "- NOT CLOSED needs: x", "NOT CLOSED"),
		childGaps("marker-first-word-after-the-dash", "- CLOSED needs: x"),
		childGaps("closed-at-the-very-end-no-newline-needs-before", "- C1 needs: x CLOSED"),
	}
	return scs
}
