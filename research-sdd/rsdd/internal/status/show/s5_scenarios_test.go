package show

import (
	"fmt"
	"strings"
)

// The S5 scenario table: full `--next` runs over the two sections of the script slice S5 ports. Group 1 is the
// retro-coverage derivation behind RETRO-DUE (_rd_covers_derive, kit #1640) and its typed states; group 2 is
// issues_due_gate (the retro enumeration, the batch prefetch, the per-retro probes, the re-verify, the budget);
// group 3 is the terminal no-garbage check of an exhausted STOP. What the children say is stated in the world's
// spec/ directory (see s5_harness_test.go).

const (
	untracked1 = "untracked: D1 first\n"
	untracked2 = "untracked: D1 first\nuntracked: D2 second\n"
	unverified = " [issue-coverage: unverified]"
)

// nblk are the block files corpus/<prefix>block<N>.md for lo..hi.
func nblk(prefix string, lo, hi int) files {
	f := files{}
	for n := lo; n <= hi; n++ {
		f[fmt.Sprintf("corpus/%sblock%d.md", prefix, n)] = "# block\n"
	}
	return f
}

// ct is a retro that declares coverage through block n.
func ct(n int) string { return fmt.Sprintf("# Retro\n\ncovers_through: B%d\n", n) }

// retros builds corpus/retros/<name> files from name, body pairs.
func retros(pairs ...string) files {
	f := files{}
	for i := 0; i+1 < len(pairs); i += 2 {
		f["corpus/retros/"+pairs[i]] = pairs[i+1]
	}
	return f
}

// spec builds spec/<name> files from name, body pairs.
func spec(pairs ...string) files {
	f := files{}
	for i := 0; i+1 < len(pairs); i += 2 {
		f["spec/"+pairs[i]] = pairs[i+1]
	}
	return f
}

func s5Scenarios() []s5Scenario {
	var scs []s5Scenario
	add := func(s ...s5Scenario) { scs = append(scs, s...) }
	due := func(bsr string) string { return one("root", "pending", 1, bsr) }
	ex := one("root", "covered", 0, "0")
	const rootGap = "NEXT | high | the root gap"
	dr := func(newest, cov, decl int) string {
		return fmt.Sprintf("[derived: newest block B%d − covers_through B%d; declared counter was %d]", newest, cov, decl)
	}
	retroNote := func(counter int, tail string) string {
		return fmt.Sprintf("RETRO-DUE | %d blocks since last retro (§18 threshold: 10)%s", counter, tail)
	}
	g := func(name, want string, r files, sp files, env map[string]string, flags ...string) s5Scenario {
		return n5(name, want, ex, merge(r, sp), env, flags...)
	}
	// the batch cache is handed to every probe: the reconcile spec of a retro's cached call is r.<name>.c.*
	a := retros("a.md", "# Retro A\n")
	ab := retros("a.md", "# Retro A\n", "b.md", "# Retro B\n")

	// --- 1. the covers_through derivation -----------------------------------------------------------------------
	blocks20 := nblk("r-", 1, 20)
	cv := func(name, want string, r files, bsr string, extra ...files) s5Scenario {
		return n5(name, want, due(bsr), merge(blocks20, append([]files{r}, extra...)...), nil)
	}
	add(
		cv("cv-coverage-lowers-the-counter-below-the-threshold", rootGap, retros("r1.md", ct(15)), "30"),
		cv("cv-coverage-lowers-but-stays-due", retroNote(15, " "+dr(20, 5, 30)), retros("r1.md", ct(5)), "30"),
		cv("cv-coverage-never-raises-the-counter", retroNote(12, ""), retros("r1.md", ct(5)), "12"),
		cv("cv-coverage-equal-to-the-counter-keeps-it", retroNote(15, ""), retros("r1.md", ct(5)), "15"),
		cv("cv-highest-coverage-of-several-retros-wins", rootGap, retros("r1.md", ct(3), "r2.md", ct(12)), "30"),
		cv("cv-coverage-through-the-newest-block", rootGap, retros("r1.md", ct(20)), "30"),
		cv("cv-two-coverage-lines-in-one-retro", rootGap, retros("r1.md", "covers_through: B2\ncovers_through: B14\n"), "30"),
		cv("cv-above-the-newest-block-is-excluded-not-clamped", retroNote(30, ""), retros("r1.md", ct(99)), "30"),
		cv("cv-excluded-value-beside-a-valid-one", rootGap, retros("r1.md", ct(99), "r2.md", ct(15)), "30"),
		cv("cv-leading-zero-declared-counter-is-shown-as-written", "RETRO-DUE | 011 blocks since last retro (§18 threshold: 10)", retros("r1.md", ct(5)), "011"),
		cv("cv-no-retros-keeps-the-declared-counter", retroNote(30, ""), nil, "30"),
		cv("cv-retro-without-the-field", retroNote(30, ""), retros("r1.md", "# Retro\n\nno field here\n"), "30"),
		cv("cv-retros-without-the-field-are-counted", retroNote(30, ""), retros("r1.md", "# R\n", "r2.md", "# R\n"), "30"),
		cv("cv-malformed-lone-letter", retroNote(30, ""), retros("m.md", "covers_through: B\n"), "30"),
		cv("cv-malformed-no-b", retroNote(30, ""), retros("m.md", "covers_through: 12\n"), "30"),
		cv("cv-malformed-no-space", retroNote(30, ""), retros("m.md", "covers_through:B12\n"), "30"),
		cv("cv-malformed-trailing-word", retroNote(30, ""), retros("m.md", "covers_through: B12 later\n"), "30"),
		cv("cv-malformed-lowercase-b", retroNote(30, ""), retros("m.md", "covers_through: b12\n"), "30"),
		cv("cv-malformed-ten-digits", retroNote(30, ""), retros("m.md", "covers_through: B0000000012\n"), "30"),
		cv("cv-nine-digit-zero-padded-value-is-valid", rootGap, retros("m.md", "covers_through: B000000015\n"), "30"),
		cv("cv-nine-digit-zero-padded-value-over-range", retroNote(30, ""), retros("m.md", "covers_through: B000000099\n"), "30"),
		cv("cv-malformed-next-to-a-valid-one", rootGap, retros("m.md", "covers_through: B\n", "r1.md", ct(15)), "30"),
		cv("cv-focus-token-with-a-bad-slug-is-malformed", retroNote(30, ""), retros("m.md", "covers_through: B15 focus=a/b\n"), "30"),
		cv("cv-indented-line-is-not-a-field", retroNote(30, ""), retros("r1.md", "  covers_through: B15\n"), "30"),
		cv("cv-fenced-backticks-are-skipped", retroNote(30, ""), retros("r1.md", "```\ncovers_through: B15\n```\n"), "30"),
		cv("cv-fenced-tildes-are-skipped", retroNote(30, ""), retros("r1.md", "~~~\ncovers_through: B15\n~~~\n"), "30"),
		cv("cv-other-fence-marker-does-not-close", retroNote(30, ""), retros("r1.md", "```\n~~~\ncovers_through: B15\n```\n"), "30"),
		cv("cv-line-after-the-fence-closes-counts", rootGap, retros("r1.md", "```\ncode\n```\ncovers_through: B15\n"), "30"),
		cv("cv-four-backtick-fence-is-closed-by-three", rootGap, retros("r1.md", "````\ncovers_through: B1\n```\ncovers_through: B15\n"), "30"),
		cv("cv-crlf-line-is-valid", rootGap, retros("r1.md", "covers_through: B15\r\n"), "30"),
		cv("cv-trailing-blanks-are-valid", rootGap, retros("r1.md", "covers_through: B15 \t\n"), "30"),
		cv("cv-root-focus-token-on-a-lone-root", rootGap, retros("r1.md", "covers_through: B15 focus=root\n"), "30"),
		cv("cv-foreign-focus-token-is-silently-ignored", retroNote(30, ""), retros("r1.md", "covers_through: B15 focus=other\n"), "30"),
		cv("cv-no-trailing-newline", rootGap, retros("r1.md", "covers_through: B15"), "30"),
		cv("cv-excluded-retro-is-not-counted", retroNote(30, ""), retros("r1.md", "<!-- kit-retro: exclude -->\n"+ct(15)), "30"),
		cv("cv-excluded-retro-beside-a-valid-one", retroNote(15, " "+dr(20, 5, 30)), retros("r1.md", "<!-- kit-retro: exclude -->\n"+ct(19), "r2.md", ct(5)), "30"),
		cv("cv-index-file-is-not-a-retro", retroNote(30, ""), retros("INDEX.md", ct(15)), "30"),
		cv("cv-name-with-index-in-it-is-not-a-retro", retroNote(30, ""), retros("reindexed.md", ct(15)), "30"),
		cv("cv-non-md-file-is-not-a-retro", retroNote(30, ""), retros("r1.txt", ct(15)), "30"),
		cv("cv-git-dir-retro-is-not-a-retro", retroNote(30, ""), files{"corpus/.git/retros/r1.md": ct(15)}, "30"),
		cv("cv-nested-retros-at-depth-four", rootGap, files{"corpus/a/b/retros/r1.md": ct(15)}, "30"),
		cv("cv-nested-retros-at-depth-five-are-not-seen", retroNote(30, ""), files{"corpus/a/b/c/retros/r1.md": ct(15)}, "30"),
		cv("cv-block-ids-use-the-newest-with-a-suffix", retroNote(25, " "+dr(30, 5, 30)), retros("r1.md", ct(5)), "30", nblk("r-", 21, 29), files{"corpus/r-block30-extra_x.md": "x"}),
		cv("cv-spanish-bloque-counts", rootGap, retros("r1.md", ct(25)), "30", files{"corpus/r-bloque30.md": "x"}),
		cv("cv-ten-digit-block-id-is-skipped", rootGap, retros("r1.md", ct(15)), "30", files{"corpus/r-block1234567890.md": "x"}),
		cv("cv-non-block-md-is-not-a-block", rootGap, retros("r1.md", ct(15)), "30", files{"corpus/notes.md": "x", "corpus/r-block99x.md": "x"}),
	)
	add(
		n5("cv-no-block-files-keeps-the-declared-counter", retroNote(30, ""), due("30"), retros("r1.md", ct(15)), nil),
		n5("cv-block-files-in-other-directories-do-not-count", retroNote(30, ""), due("30"), merge(retros("r1.md", ct(15)), files{"corpus/sub/r-block9.md": "x"}), nil),
		n5("cv-range-scoped-focus-keeps-the-declared-counter", retroNote(30, ""), due("30"),
			merge(nblk("x-", 1, 20), retros("r1.md", ct(15)), files{"corpus/FOCUSES.md": fcHeader + fcRoot("", "B1–B20")}), nil),
		n5("cv-root-prefix-from-focuses-md-scopes-the-newest-block", rootGap, due("30"),
			merge(nblk("x-", 1, 20), nblk("y-", 21, 40), retros("r1.md", ct(15)), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x-", "")}), nil),
		n5("cv-without-the-root-prefix-every-family-counts", retroNote(25, " "+dr(40, 15, 30)), due("30"),
			merge(nblk("x-", 1, 20), nblk("y-", 21, 40), retros("r1.md", ct(15))), nil),
		m5("cv-unmatched-paren-slug-reports-grep-and-finds-no-blocks", retroNote(30, ""),
			merge(files{"corpus/RESEARCH-STATE-(x.md": one("x", "pending", 1, "30")}, nblk("(x-", 1, 20), retros("r1.md", "covers_through: B15 focus=(x\n")), nil, "--focus", "(x"),
		n5("cv-unreadable-directory-keeps-the-declared-counter", retroNote(30, ""), due("30"), merge(blocks20, retros("r1.md", ct(15)), files{"corpus/locked/": ""}), nil),
		n5("cv-unreadable-retro-is-counted-without-lines", retroNote(30, ""), due("30"), merge(blocks20, retros("r1.md", ct(15))), nil),
		n5("cv-symlinked-retro-is-not-a-retro", retroNote(30, ""), due("30"), merge(blocks20, files{"corpus/real/r1.md": ct(15)}), nil),
	)
	// the multi-focus corpus: only a `focus=<own slug>` line is a focus's evidence
	multi := func(rootBsr, actBsr string, extra ...files) files {
		return merge(files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, rootBsr), "corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, actBsr)},
			append([]files{nblk("act-", 1, 20)}, extra...)...)
	}
	add(
		m5("cv-multi-unscoped-line-is-ignored-and-named", retroNote(30, ""), multi("30", "0", retros("r1.md", ct(15))), nil),
		m5("cv-multi-root-focus-line-counts-for-the-root", "NEXT | high | the act gap", multi("30", "0", retros("r1.md", "covers_through: B15 focus=root\n")), nil),
		m5("cv-multi-other-focus-line-is-not-the-roots", retroNote(30, ""), multi("30", "0", retros("r1.md", "covers_through: B15 focus=act\n")), nil),
		m5("cv-multi-slug-focus-line-counts-for-that-focus", "NEXT | high |", multi("0", "30", retros("r1.md", "covers_through: B15 focus=act\n")), nil),
		m5("cv-multi-two-unscoped-lines-are-named-with-a-count", retroNote(30, ""), multi("30", "0", retros("r1.md", ct(15), "r2.md", ct(16))), nil),
		m5("cv-multi-duplicate-slug-is-refused", retroNote(30, ""),
			merge(multi("30", "0", retros("r1.md", "covers_through: B15 focus=root\n")), files{"corpus/RESEARCH-STATE-.md": one("dup", "pending", 1, "0")}), nil),
		m5("cv-lone-slugged-state-needs-its-own-focus-line", retroNote(30, ""),
			merge(files{"corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "30")}, nblk("act-", 1, 20), retros("r1.md", ct(15))), nil, "--focus", "act"),
		m5("cv-lone-slugged-state-with-its-own-focus-line", "NEXT | high |",
			merge(files{"corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "30")}, nblk("act-", 1, 20), retros("r1.md", "covers_through: B15 focus=act\n")), nil, "--focus", "act"),
		m5("cv-aggregate-walks-each-state", retroNote(30, ""),
			multi("30", "30", retros("r1.md", "covers_through: B15 focus=act\n")), nil),
	)
	add(
		n5("cv-derived-note-reaches-the-scoped-pick", retroNote(15, " "+dr(20, 5, 30)), due("30"), merge(blocks20, retros("r1.md", ct(5))), nil, "--root"),
	)

	// --- 2. issues_due_gate -------------------------------------------------------------------------------------
	const pairKey = "r.a.md.c.out"
	add(
		g("idg-no-retros-is-a-clean-stop", stopLine, nil, nil, nil),
		g("idg-clean-retro", stopLine, a, spec(), nil),
		g("idg-applied-retro-is-skipped", stopLine, retros("a.md", "<!-- review-status: applied -->\n# A\n"), spec(pairKey, untracked1), nil),
		g("idg-dismissed-retro-is-skipped", stopLine, retros("a.md", "<!-- review-status: dismissed -->\n# A\n"), spec(pairKey, untracked1), nil),
		g("idg-partial-marker-is-probed", "ISSUES-DUE | 1 untracked delta(s) in", retros("a.md", "<!-- review-status: partial -->\n# A\n"), spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-marker-outside-the-leading-block-is-probed", "ISSUES-DUE | 1", retros("a.md", "# A\n\ntext\n<!-- review-status: applied -->\n"), spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-untracked-is-reverified-and-issues-due", "ISSUES-DUE | 2 untracked delta(s) in", a, spec(pairKey, untracked2, "r.a.md.out", untracked2), nil),
		g("idg-reverified-count-wins-over-the-batch-count", "ISSUES-DUE | 1 untracked delta(s) in", a, spec(pairKey, untracked2, "r.a.md.out", untracked1), nil),
		g("idg-batch-false-negative-is-cleared-by-the-reverify", stopLine, a, spec(pairKey, untracked1), nil),
		g("idg-tracked-output-lines-are-not-untracked", stopLine, a, spec(pairKey, "tracked: D1 #5\n  untracked: indented\nuntracked-ish: x\n"), nil),
		g("idg-untracked-count-needs-the-prefix-at-line-start", "ISSUES-DUE | 1 ", a, spec(pairKey, "noise\nuntracked: D1\n", "r.a.md.out", "noise\nuntracked: D1\n"), nil),
		g("idg-reverify-timeout-is-unverified", stopLine+unverified, a, spec(pairKey, untracked1, "r.a.md.sleep", "3"), map[string]string{"_IDG_RECONCILE_TIMEOUT_SECS": "1"}),
		g("idg-reverify-degraded-is-unverified", stopLine+unverified, a, spec(pairKey, untracked1, "r.a.md.rc", "1", "r.a.md.err", "degraded: gh not authenticated\n"), nil),
		g("idg-reverify-failure-is-unverified", stopLine+unverified, a, spec(pairKey, untracked1, "r.a.md.rc", "3", "r.a.md.err", "boom\nsecond\n"), nil),
		g("idg-reverify-failure-without-stderr", stopLine+unverified, a, spec(pairKey, untracked1, "r.a.md.rc", "3"), nil),
		g("idg-batch-failure-falls-back-to-per-retro", "ISSUES-DUE | 1 untracked delta(s) in", a, spec("gh.rc", "1", "r.a.md.out", untracked1), nil),
		g("idg-batch-failure-fallback-clean", stopLine, a, spec("gh.rc", "1"), nil),
		g("idg-batch-timeout-falls-back", stopLine, a, spec("gh.sleep", "3"), map[string]string{"_IDG_RECONCILE_TIMEOUT_SECS": "1"}),
		g("idg-gh-exit-127-falls-back", stopLine, a, spec("gh.rc", "127"), nil),
		g("idg-batch-bodies-reach-the-cache", stopLine, a, spec("gh.out", "body one\n\nbody two\n\n\n"), nil),
		g("idg-batch-limit-is-passed-through", stopLine, a, nil, map[string]string{"_IDG_BATCH_LIMIT": "7"}),
		g("idg-empty-batch-limit-is-the-default", stopLine, a, nil, map[string]string{"_IDG_BATCH_LIMIT": ""}),
		g("idg-probe-timeout-is-unverified", stopLine+unverified, a, spec(pairKey, "", "r.a.md.c.sleep", "3"), map[string]string{"_IDG_RECONCILE_TIMEOUT_SECS": "1"}),
		g("idg-probe-degraded-is-unverified", stopLine+unverified, a, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: gh unavailable\n"), nil),
		g("idg-probe-degraded-on-a-later-stderr-line", stopLine+unverified, a, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "note\ndegraded: gh unavailable\n"), nil),
		g("idg-probe-failure-is-unverified", stopLine+unverified, a, spec("r.a.md.c.rc", "2", "r.a.md.c.err", "boom\n"), nil),
		g("idg-probe-failure-without-stderr", stopLine+unverified, a, spec("r.a.md.c.rc", "2"), nil),
		g("idg-probe-failure-keeps-multiline-stderr", stopLine+unverified, a, spec("r.a.md.c.rc", "2", "r.a.md.c.err", "one\ntwo\n\n\n"), nil),
		g("idg-degraded-word-mid-line-is-a-failure", stopLine+unverified, a, spec("r.a.md.c.rc", "2", "r.a.md.c.err", "x degraded: y\n"), nil),
		g("idg-out-of-scope-marker-is-unverified", stopLine+unverified, a, spec("r.a.md.c.err", "out-of-scope-marker: a.md\n"), nil),
		g("idg-out-of-scope-marker-with-untracked-is-unverified", stopLine+unverified, a, spec("r.a.md.c.err", "out-of-scope-marker: a.md\n", pairKey, untracked1), nil),
		g("idg-stderr-noise-on-success-is-not-unverified", stopLine, a, spec("r.a.md.c.err", "note: fine\n"), nil),
		g("idg-first-untracked-retro-ends-the-walk", "ISSUES-DUE | 1 untracked delta(s) in", ab, spec(pairKey, untracked1, "r.a.md.out", untracked1, "r.b.md.c.out", untracked1), nil),
		g("idg-later-untracked-retro-after-a-clean-one", "ISSUES-DUE | 2 untracked delta(s) in", ab, spec("r.b.md.c.out", untracked2, "r.b.md.out", untracked2), nil),
		g("idg-unverified-wins-over-clean", stopLine+unverified, ab, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: x\n"), nil),
		g("idg-untracked-wins-over-unverified", "ISSUES-DUE | 1 untracked delta(s) in", ab, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: x\n", "r.b.md.c.out", untracked1, "r.b.md.out", untracked1), nil),
		g("idg-aggregate-budget-exceeded-is-unverified", stopLine+unverified, ab, spec(), map[string]string{"_IDG_AGGREGATE_BUDGET_SECS": "0"}),
		g("idg-probes-run-in-byte-order", "ISSUES-DUE | 1 untracked delta(s) in", retros("a.md", "# A\n", "B.md", "# B\n"), spec("r.B.md.c.out", untracked1, "r.B.md.out", untracked1, "r.a.md.c.out", untracked1, "r.a.md.out", untracked1), nil),
		g("idg-index-and-non-md-files-are-not-probed", stopLine, retros("a.md", "<!-- review-status: applied -->\n", "INDEX.md", "# I\n", "x.txt", "t\n", "myIndex.md", "# I\n"), spec("r.INDEX.md.c.out", untracked1), nil),
		g("idg-git-dir-retros-are-not-probed", stopLine, files{"corpus/.git/retros/a.md": "# A\n"}, nil, nil),
		g("idg-nested-retros-at-depth-four-are-probed", "ISSUES-DUE | 1 untracked delta(s) in", files{"corpus/a/b/retros/a.md": "# A\n"}, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-nested-retros-at-depth-five-are-not-probed", stopLine, files{"corpus/a/b/c/retros/a.md": "# A\n"}, spec(pairKey, untracked1), nil),
		g("idg-retros-directory-must-be-named-retros", stopLine, files{"corpus/notretros/a.md": "# A\n", "corpus/retros-old/a.md": "# A\n"}, spec(pairKey, untracked1), nil),
		g("idg-exhausted-root-flag-runs-the-gate", "ISSUES-DUE | 1 untracked delta(s) in", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil, "--root"),
		m5("idg-exhausted-focus-flag-runs-the-gate", "ISSUES-DUE | 1 untracked delta(s) in",
			merge(files{"corpus/RESEARCH-STATE.md": ex, "corpus/RESEARCH-STATE-act.md": one("act", "covered", 0, "0")}, a, spec(pairKey, untracked1, "r.a.md.out", untracked1)), nil, "--focus", "act"),
		g("idg-unreadable-directory-makes-the-listing-incomplete", stopLine+unverified, a, spec(), nil),
		g("idg-unreadable-directory-still-probes-what-it-sees", "ISSUES-DUE | 1 untracked delta(s) in", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-symlinked-retro-is-not-probed", stopLine, merge(retros("a.md", "<!-- review-status: applied -->\n")), spec("r.l.md.c.out", untracked1), nil),
		g("idg-unreadable-retro-is-probed-like-any-other", "ISSUES-DUE | 1 untracked delta(s) in", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-unverified-stop-keeps-the-backlog-qualifier", stopLine+unverified+" [backlog-unreadable: 1 rows]", a, nil, nil),
		g("idg-clean-stop-keeps-the-backlog-qualifier", stopLine+" [backlog-unreadable: 1 rows]", a, nil, nil),
	)
	// the target as the caller wrote it is what the paths print: relative, and with a trailing slash
	add(
		g("idg-relative-target-prints-relative-paths", "ISSUES-DUE | 1 untracked delta(s) in corpus/retros/a.md — seed: stage-retro-issues.sh corpus/retros/a.md --apply", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
		g("idg-trailing-slash-target-does-not-double-the-slash", "ISSUES-DUE | 1 untracked delta(s) in <ROOT>/corpus/retros/a.md", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), nil),
	)
	scs[len(scs)-2].runs, scs[len(scs)-2].cwd = [][]string{{"corpus", "--next"}}, "."
	scs[len(scs)-1].runs = [][]string{{"{ROOT}/corpus/", "--next"}}
	// the two backlog-qualifier scenarios need a state with one unread row; the rest of the world is the gate's
	bu := strings.Replace(st4("", "0", 0, "", row("high", "done gap", "covered"), "| 1 | numbered one | web | pending |"), "## Gap-backlog (prioritized)", "## Gap backlog", 1)
	for i := range scs {
		switch scs[i].name {
		case "idg-unverified-stop-keeps-the-backlog-qualifier":
			scs[i].files["spec/r.a.md.c.rc"], scs[i].files["spec/r.a.md.c.err"] = "1", "degraded: x\n"
			fallthrough
		case "idg-clean-stop-keeps-the-backlog-qualifier":
			scs[i].files[stateRel] = bu
		}
	}

	// --- 3. the terminal no-garbage check ---------------------------------------------------------------------
	on := map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}
	cc := func(extra map[string]string) map[string]string {
		m := map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	add(
		g("cc-clean", stopLine, nil, nil, on),
		g("cc-clean-after-a-verified-clean-gate", stopLine, a, nil, on),
		g("cc-runs-after-the-unverified-stop", stopLine+unverified, a, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: x\n"), on),
		g("cc-does-not-run-after-issues-due", "ISSUES-DUE | 1", a, spec(pairKey, untracked1, "r.a.md.out", untracked1), on),
		g("cc-findings", stopLine, nil, spec("cc.rc", "1", "cc.out", "GARBAGE untracked a.txt\nGARBAGE untracked b.txt\n"), on),
		g("cc-findings-without-output", stopLine, nil, spec("cc.rc", "1"), on),
		g("cc-findings-keep-leading-blanks", stopLine, nil, spec("cc.rc", "1", "cc.out", "  indented finding\n\nafter blank\n\n\n"), on),
		g("cc-unverifiable-exit-2-names-the-last-line", stopLine, nil, spec("cc.rc", "2", "cc.out", "first line\nlast line\n"), on),
		g("cc-unverifiable-exit-3-without-output", stopLine, nil, spec("cc.rc", "3"), on),
		g("cc-unverifiable-exit-127", stopLine, nil, spec("cc.rc", "127", "cc.out", "bash: boom\n"), on),
		g("cc-exit-137-is-a-timeout", stopLine, nil, spec("cc.rc", "137"), on),
		g("cc-exit-124-is-a-timeout", stopLine, nil, spec("cc.rc", "124"), on),
		g("cc-timeout-bound-fires", stopLine, nil, spec("cc.sleep", "3"), cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "1"})),
		g("cc-invalid-timeout-word", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "abc"})),
		g("cc-invalid-timeout-zero", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "0"})),
		g("cc-invalid-timeout-zeros", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "000"})),
		g("cc-invalid-timeout-negative", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "-5"})),
		g("cc-invalid-timeout-fraction", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "1.5"})),
		g("cc-empty-timeout-is-the-default", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": ""})),
		g("cc-padded-timeout-is-normalised", stopLine, nil, nil, cc(map[string]string{"RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "010"})),
		g("cc-skipped-by-the-switch", stopLine, nil, spec("cc.rc", "1", "cc.out", "never\n"), map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "1"}),
		g("cc-only-the-exact-switch-value-skips", stopLine, nil, spec("cc.rc", "1", "cc.out", "ran\n"), map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "true"}),
		g("cc-scoped-stop-runs-it", stopLine, nil, nil, on, "--root"),
	)
	add(g("cc-script-not-beside-the-status-script", stopLine, nil, nil, on).withoutCC())

	// worlds with an unreadable directory or file, and a link: set after the table is built
	for i := range scs {
		sc := &scs[i]
		switch sc.name {
		case "cv-unreadable-directory-keeps-the-declared-counter", "idg-unreadable-directory-makes-the-listing-incomplete", "idg-unreadable-directory-still-probes-what-it-sees":
			sc.files["corpus/locked/x.md"] = "x\n"
			sc.unreadable, sc.needsUser = []string{"corpus/locked"}, true
		case "cv-unreadable-retro-is-counted-without-lines":
			sc.unreadable, sc.needsUser = []string{"corpus/retros/r1.md"}, true
		case "idg-unreadable-retro-is-probed-like-any-other":
			sc.unreadable, sc.needsUser = []string{"corpus/retros/a.md"}, true
		case "cv-symlinked-retro-is-not-a-retro":
			sc.links = map[string]string{"corpus/retros/r1.md": "{ROOT}/corpus/real/r1.md"}
		case "idg-symlinked-retro-is-not-probed":
			sc.links = map[string]string{"corpus/retros/l.md": "{ROOT}/corpus/retros/a.md"}
		}
	}
	return scs
}
