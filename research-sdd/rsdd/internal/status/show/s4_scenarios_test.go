package show

import "strings"

// The S4 scenario table: full `--next` runs. The groups are the cases of the suites issue #2549 names for S4
// (-next-scope, -focus-scope, -followups, -queue, -unreadable-stop) and the --next ordering cases of the main
// suite, plus the branches of the frozen block they do not reach: the STALE gate and its stopped-focus bypass, the
// RETRO-DUE scoping, the paused/stopped skip, the unscoped aggregate and the scoped verdict.

const (
	stopLine = "STOP | read-only-investigable exhausted (0)"
	blockHdr = "\n## Blocked gaps (each tagged with what it needs)\n\n"
)

// blk marks one blocked_open in the envelope (the blocked-gaps section the scenario appends carries one entry).
func blk(state string) string { return strings.Replace(state, "blocked_open: 0", "blocked_open: 1", 1) }

func s4Scenarios() []s4Scenario {
	var scs []s4Scenario
	add := func(s ...s4Scenario) { scs = append(scs, s...) }

	// --- 1. the walk of resolve_next: tiers, leading token, struck names, the blocked set ------------------------
	rows3 := []string{row("low", "L1 low gap", "pending"), row("medium", "M1 medium gap", "pending"), row("high", "H1 high gap", "pending")}
	add(
		n4("ord-high-before-medium-and-low", "NEXT | high | H1 high gap", st4("", "0", -1, "", rows3...), nil),
		n4("ord-medium-before-low", "NEXT | medium | M1 medium gap", st4("", "0", -1, "", row("low", "L1 low gap", "pending"), row("medium", "M1 medium gap", "pending")), nil),
		n4("ord-first-row-of-a-tier", "NEXT | high | A first", st4("", "0", -1, "", row("high", "A first", "pending"), row("high", "B second", "pending")), nil),
		n4("ord-low-only", "NEXT | low | L1 low gap", st4("", "0", -1, "", row("low", "L1 low gap", "pending")), nil),
		n4("ord-decorated-pending", "NEXT | high | G1 decorated", st4("", "0", 1, "", row("high", "G1 decorated", "pending (uncovered by B7)")), nil),
		n4("ord-bold-pending-with-note", "NEXT | high | G1 bold", st4("", "0", 0, "", row("high", "G1 bold", "**pending** (note)")), nil),
		n4("ord-pending-prefix-is-not-pending", "NEXT | low | L2 real", st4("", "0", 1, "", row("high", "H1 nope", "pendingly"), row("high", "H2 nope", "pending-review"), row("low", "L2 real", "pending")), nil),
		n4("ord-empty-gap-cell-skipped", "NEXT | low | L2 real", st4("", "0", 1, "", "| high |  | web | pending |", row("low", "L2 real", "pending")), nil),
		n4("ord-not-pending-is-skipped", "NEXT | low | L2 real", st4("", "0", 1, "", row("high", "H1 nope", "not pending"), row("low", "L2 real", "pending")), nil),
		n4("ord-blocked-pending-review-is-skipped", "NEXT | low | L2 real", st4("", "0", 1, "", row("high", "H1 stuck", "blocked (pending review)"), row("low", "L2 real", "pending")), nil),
		n4("ord-struck-gap-name-is-skipped", "NEXT | high | H2 live", st4("", "0", -1, "", row("high", "~~H1 old~~", "pending"), row("high", "H2 live", "pending")), nil),
		n4("ord-gap-with-partial-strike-is-skipped", "NEXT | medium | M1 live", st4("", "0", -1, "", row("high", "H1 ~~part~~ old", "pending"), row("medium", "M1 live", "pending")), nil),
		n4("ord-blocked-section-name-is-skipped", "NEXT | medium | G2 second",
			blk(st4("", "0", 1, blockHdr+"- G1 first — needs: hardware\n", row("high", "G1 first", "pending"), row("medium", "G2 second", "pending"))), nil),
		n4("ord-blocked-section-lookalike-name-is-not-blocked", "NEXT | high | G1 first gap",
			blk(st4("", "0", 1, blockHdr+"- G1 — needs: hardware\n", row("high", "G1 first gap", "pending"))), nil),
		n4("ord-all-covered-stops", stopLine, st4("", "0", 0, "", row("high", "H1 done", "covered"), row("low", "L1 done", "✅ done")), nil),
		n4("ord-no-rows-stops", stopLine, st4("", "0", 0, ""), nil),
		n4("ord-deferred-tier-is-not-walked", stopLine, st4("", "0", 0, "", row("deferred", "D1 parked", "pending")), nil),
		n4("ord-requires-execution-is-not-served", stopLine, strings.NewReplacer("requires_execution_open: 0", "requires_execution_open: 1", "requires-execution**: 0", "requires-execution**: 1").Replace(st4("", "0", 0, "", row("high", "H1 hw", "requires-execution"))), nil),
		n4("ord-in-progress-is-not-served", stopLine, st4("", "0", 0, "", row("high", "H1 half", "in-progress")), nil),
		n4("ord-unknown-priority-row-is-stale", "STALE | ", st4("", "0", 1, "", row("P0", "X0 numbered", "pending"), row("high", "H1 live", "pending")), nil),
		n4("ord-uppercase-priority-is-folded", "NEXT | high | H1 live", st4("", "0", 1, "", row("HIGH", "H1 live", "pending")), nil),
		n4("ord-medium-listed-before-high", "NEXT | high | H1 high gap", st4("", "0", -1, "", row("medium", "M1 medium gap", "pending"), row("high", "H1 high gap", "pending")), nil),
		n4("ord-empty-gap-cell-is-skipped", "NEXT | low | L1 low gap", st4("", "0", 1, "", row("high", "", "pending"), row("low", "L1 low gap", "pending")), nil),
		n4("ord-struck-priority-row-is-not-served", stopLine, st4("", "0", 0, "", row("~~high~~", "H1 gone", "pending")), nil),
		n4("ord-crlf-state-file-is-stale", "STALE | ", strings.ReplaceAll(st4("", "0", 1, "", row("high", "H1 live", "pending")), "\n", "\r\n"), nil),
		n4("ord-no-trailing-newline", "NEXT | high | H1 live", strings.TrimSuffix(st4("", "0", 1, "", row("high", "H1 live", "pending")), "\n"), nil),
		m4("ord-five-column-table", "NEXT | high |", files{stateRel: "# S\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n\n" + h5 + "\n| high | G1 | five col | web | pending |\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 1\n- **Open gaps — requires-execution**: 0\n- **Open gaps — blocked**: 0\n"}),
		n4("ord-relative-target", "NEXT | high | H1 live", st4("", "0", 1, "", row("high", "H1 live", "pending")), nil),
	)
	scs[len(scs)-1].runs = [][]string{{"corpus", "--next"}}
	scs[len(scs)-1].cwd = "."

	// --- 2. the RETRO-DUE threshold and its scope -------------------------------------------------------------
	for _, c := range []struct{ name, bsr, want string }{
		{"retro-threshold-10-is-not-due", "10", "NEXT | high | the root gap"},
		{"retro-threshold-11-is-due", "11", "RETRO-DUE | 11 blocks since last retro (§18 threshold: 10)"},
		{"retro-leading-zero-counts-decimal", "011", "RETRO-DUE | 011 blocks since last retro (§18 threshold: 10)"},
		{"retro-leading-zero-below", "010", "NEXT | high | the root gap"},
		{"retro-non-numeric-counter-is-stale", "many", "STALE | "},
		{"retro-negative-counter-is-stale", "-3", "STALE | "},
		{"retro-absent-is-ignored", "", "NEXT | high | the root gap"},
		{"retro-zero", "0", "NEXT | high | the root gap"},
	} {
		add(n4(c.name, c.want, one("root", "pending", 1, c.bsr), nil))
	}
	add(
		n4("retro-due-wins-over-an-open-gap", "RETRO-DUE | 25 blocks", one("root", "pending", 1, "25"), nil),
	)
	add(
		m4("retro-stopped-focus-is-skipped", "NEXT | high | the root gap", files{
			"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "pending", 1, "30"),
			"corpus/FOCUSES.md": focusRows("old", "stopped")}),
		m4("retro-paused-focus-is-skipped", "NEXT | high | the root gap", files{
			"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "pending", 1, "30"),
			"corpus/FOCUSES.md": focusRows("old", "paused")}),
		m4("retro-active-focus-in-a-multi-focus-corpus", "RETRO-DUE | 30 blocks", files{
			"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "pending", 1, "30"),
			"corpus/FOCUSES.md": focusRows("old", "open")}),
	)

	// --- 3. the scope fixtures of the -next-scope suite --------------------------------------------------------
	fxA := files{"corpus/RESEARCH-STATE.md": one("root", "covered", 0, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "0")}
	fxB := files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "covered", 0, "0")}
	fxC := files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "11")}
	fxD := files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/z/RESEARCH-STATE-x.md": one("x", "pending", 0, "0"),
		"corpus/z/FOCUSES.md": focusRows("x", "stopped")}
	fxE := files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "pending", 0, "0")}
	for _, c := range []struct {
		name, want string
		f          files
		flags      []string
	}{
		{"scope-A-no-flag", "NEXT | high | the act gap", fxA, nil},
		{"scope-A-root", stopLine, fxA, []string{"--root"}},
		{"scope-A-focus", "NEXT | high | the act gap", fxA, []string{"--focus", "act"}},
		{"scope-A-all", "NEXT | high | the act gap", fxA, []string{"--all"}},
		{"scope-B-no-flag", "NEXT | high | the root gap", fxB, nil},
		{"scope-B-root", "NEXT | high | the root gap", fxB, []string{"--root"}},
		{"scope-B-focus", stopLine, fxB, []string{"--focus", "act"}},
		{"scope-B-all", "NEXT | high | the root gap", fxB, []string{"--all"}},
		{"scope-C-no-flag-retro-from-the-aggregate", "RETRO-DUE | 11 blocks", fxC, nil},
		{"scope-C-root-ignores-the-focus-debt", "NEXT | high | the root gap", fxC, []string{"--root"}},
		{"scope-C-focus-retro-from-the-pick", "RETRO-DUE | 11 blocks", fxC, []string{"--focus", "act"}},
		{"scope-C-all", "RETRO-DUE | 11 blocks", fxC, []string{"--all"}},
		{"scope-D-root-survives-the-stale-bypass", "NEXT | high | the root gap", fxD, []string{"--root"}},
		{"scope-D-no-flag", "NEXT | high | the root gap", fxD, nil},
		{"scope-E-active-stale-sibling-no-flag", "STALE | ", fxE, nil},
		{"scope-E-active-stale-sibling-root", "STALE | ", fxE, []string{"--root"}},
		{"scope-E-focus-act-when-the-sibling-is-clean", "NEXT | high | the act gap", merge(fxE, files{"corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "0")}), []string{"--focus", "act"}},
	} {
		add(m4(c.name, c.want, c.f, c.flags...))
	}

	// --- 4. the STALE gate: the line, the focus naming, the first failure, the stopped-focus bypass --------------
	bad := func(name string) string { return one(name, "pending", 0, "0") } // declares 0 with one pending gap
	good := func(name string) string { return one(name, "pending", 1, "0") }
	add(
		n4("stale-single", "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh ", bad("the"), nil),
		n4("stale-single-root-flag", "STALE | ", bad("the"), nil, "--root"),
		m4("stale-multi-names-the-failing-focus", "STALE | ", files{"corpus/RESEARCH-STATE-good.md": good("good"), "corpus/RESEARCH-STATE-broken.md": bad("broken")}),
		m4("stale-multi-focus-flag-scopes-the-gate", "NEXT | high | the good gap", files{"corpus/RESEARCH-STATE-good.md": good("good"), "corpus/RESEARCH-STATE-broken.md": bad("broken")}, "--focus", "good"),
		m4("stale-multi-focus-flag-own-defect", "STALE | ", files{"corpus/RESEARCH-STATE-good.md": good("good"), "corpus/RESEARCH-STATE-broken.md": bad("broken")}, "--focus", "broken"),
		m4("stale-multi-all-flag", "STALE | ", files{"corpus/RESEARCH-STATE-good.md": good("good"), "corpus/RESEARCH-STATE-broken.md": bad("broken")}, "--all"),
		m4("stale-two-failing-names-the-first-in-sort-order", "STALE | ", files{"corpus/RESEARCH-STATE-aaa.md": bad("aaa"), "corpus/RESEARCH-STATE-mmm.md": good("mmm"), "corpus/RESEARCH-STATE-zzz.md": bad("zzz")}),
		m4("stale-empty-slug-file-is-not-a-focus", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-.md": bad("dash")}),
		m4("stale-root-fallback-names-the-root-file", "STALE | ", files{"corpus/RESEARCH-STATE.md": bad("root"), "corpus/RESEARCH-STATE-good.md": good("good")}),
		m4("stale-legacy-corpus-wide", "STALE | ", files{"corpus/RESEARCH-STATE-active.md": good("active"), "corpus/RESEARCH-STATE-legacy.md": legacy("## Gap-backlog (prioritized)"), "corpus/RESEARCH-STATE-oldnotes.md": legacy("## Backlog notes")}),
		m4("stale-legacy-focus-scopes-the-gate", "NEXT | high | the active gap", files{"corpus/RESEARCH-STATE-active.md": good("active"), "corpus/RESEARCH-STATE-legacy.md": legacy("## Gap-backlog (prioritized)"), "corpus/RESEARCH-STATE-oldnotes.md": legacy("## Backlog notes")}, "--focus", "active"),
		m4("stale-legacy-focus-its-own-defects", "STALE | ", files{"corpus/RESEARCH-STATE-active.md": good("active"), "corpus/RESEARCH-STATE-legacy.md": legacy("## Gap-backlog (prioritized)")}, "--focus", "legacy"),
		m4("stale-legacy-single-focus", "STALE | ", files{"corpus/RESEARCH-STATE-legacy.md": legacy("## Gap-backlog (prioritized)")}),
		m4("stale-legacy-single-focus-flag", "STALE | ", files{"corpus/RESEARCH-STATE-legacy.md": legacy("## Gap-backlog (prioritized)")}, "--focus", "legacy"),
		m4("stale-single-focus-clean-all-agree", "NEXT | high | the active gap", files{"corpus/RESEARCH-STATE-active.md": good("active")}, "--all"),
	)

	// the stopped/paused bypass of the multi-focus STALE gate (kit #194, #641)
	stale0 := one("x", "pending", 0, "0") // a stale envelope on a focus that still lists a pending gap
	add(
		m4("bypass-stopped-stale-focus-is-forgiven", "NEXT | high | the root gap", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": stale0, "corpus/FOCUSES.md": focusRows("x", "stopped")}),
		m4("bypass-paused-stale-focus-is-forgiven", "NEXT | high | the root gap", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": stale0, "corpus/FOCUSES.md": focusRows("x", "paused")}),
		m4("bypass-active-stale-focus-is-stale", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": stale0, "corpus/FOCUSES.md": focusRows("x", "open")}),
		m4("bypass-no-focuses-file-is-stale", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": stale0}),
		m4("bypass-stopped-invalid-priority-focus-is-forgiven", "NEXT | high | the root gap", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": legacy("## Gap-backlog (prioritized)"), "corpus/FOCUSES.md": focusRows("x", "stopped")}),
		m4("bypass-active-invalid-priority-focus-is-stale", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": legacy("## Gap-backlog (prioritized)"), "corpus/FOCUSES.md": focusRows("x", "open")}),
		m4("bypass-active-focus-without-envelope-marker", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"),
			"corpus/RESEARCH-STATE-x.md": strings.NewReplacer("<!-- research-state.v1 -->", "", "<!-- /research-state.v1 -->", "").Replace(good("x")), "corpus/FOCUSES.md": focusRows("x", "open")}),
		m4("bypass-active-focus-with-matching-envelope-but-gc-eq-kg", "STALE | ", files{"corpus/RESEARCH-STATE.md": good("root"),
			"corpus/RESEARCH-STATE-x.md": strings.NewReplacer("gaps_closed: 0", "gaps_closed: 4", "known_gaps: 0", "known_gaps: 4").Replace(good("x")), "corpus/FOCUSES.md": focusRows("x", "open")}),
		m4("bypass-consistent-active-siblings-pass-every-mirror-check", "NEXT | high | the x gap", files{"corpus/RESEARCH-STATE.md": good("root"), "corpus/RESEARCH-STATE-x.md": good("x"),
			"corpus/RESEARCH-STATE-y.md": stale0, "corpus/FOCUSES.md": focusRows("x", "open", "y", "stopped")}),
		m4("bypass-open-focus-with-no-open-gap-is-a-stopped-one", "NEXT | high | the root gap", files{"corpus/RESEARCH-STATE.md": good("root"),
			"corpus/RESEARCH-STATE-x.md": one("x", "covered", 5, "0"), "corpus/FOCUSES.md": focusRows("x", "open")}),
	)

	// the fake verify-state: the first failure extractor over shapes a real report does not produce on demand
	fakeCase := func(name, want, out string, rc int, flags ...string) s4Scenario {
		sc := n4(name, want, st4("", "0", -1, "", row("high", "G1 gap", "pending")), nil, flags...)
		sc.fake = &fakeVerify{out, rc}
		return sc
	}
	long := strings.Repeat("a", 156) + strings.Repeat("é", 10)
	add(
		fakeCase("ff-no-fail-line-rc-1", "STALE | ", "== verify-state: x ==\n== exit 1 ==\n", 1),
		fakeCase("ff-empty-report-rc-1", "STALE | ", "", 1),
		fakeCase("ff-fail-with-file-header", "STALE | ", "== verify-state: RESEARCH-STATE.md (target: t) ==\n   FAIL   envelope investigable_open=0 != 1\n== exit 1 ==\n", 1),
		fakeCase("ff-fail-without-header", "STALE | ", "   FAIL   no header here\n", 1),
		fakeCase("ff-last-header-wins", "STALE | ", "== verify-state: A.md (target: t) ==\n== verify-state: B.md (target: t) ==\n   FAIL   boom\n", 1),
		fakeCase("ff-header-without-target-suffix", "STALE | ", "== verify-state: plain.md ==\n   FAIL   boom\n", 1),
		fakeCase("ff-first-fail-wins", "STALE | ", "== verify-state: A.md (target: t) ==\n   FAIL   first\n   FAIL   second\n", 1),
		fakeCase("ff-truncated-on-a-character-boundary", "STALE | ", "== verify-state: RESEARCH-STATE.md (target: t) ==\n   FAIL   "+long+"\n", 1),
		fakeCase("ff-exactly-160-bytes-is-kept", "STALE | ", "== verify-state: f ==\n   FAIL   "+strings.Repeat("b", 160)+"\n", 1),
		fakeCase("ff-161-bytes-is-cut", "STALE | ", "== verify-state: f ==\n   FAIL   "+strings.Repeat("b", 161)+"\n", 1),
		fakeCase("ff-multibyte-straddles-the-cut", "STALE | ", "== verify-state: f ==\n   FAIL   "+strings.Repeat("b", 156)+"€€€€\n", 1),
		fakeCase("ff-colon-fail-takes-the-value-line", "STALE | ", "== verify-state: f ==\n   FAIL   backlog NOT FULLY PARSEABLE — unknown priority value(s) found:\n          unknown priority value [SES2] — valid: high\n== exit 1 ==\n", 1),
		fakeCase("ff-colon-fail-at-end-of-report", "STALE | ", "== verify-state: f ==\n   FAIL   dangling:\n", 1),
		fakeCase("ff-colon-fail-value-line-is-a-header", "STALE | ", "== verify-state: f ==\n   FAIL   dangling:\n== verify-state: g (target: t) ==\n          the value\n", 1),
		fakeCase("ff-colon-fail-value-line-is-a-fail", "STALE | ", "== verify-state: f ==\n   FAIL   dangling:\n   FAIL   next\n", 1),
		func() s4Scenario {
			sc := m4("ff-multi-focus-fake-names-every-focus", "STALE | ", files{"corpus/RESEARCH-STATE-a.md": good("a"), "corpus/RESEARCH-STATE-b.md": bad("b")})
			sc.fake = &fakeVerify{"== verify-state: RESEARCH-STATE-a.md (target: t) ==\n   FAIL   boom\n", 1}
			return sc
		}(),
		fakeCase("ff-rc-0-with-no-fail-line-still-passes-the-gate", "NEXT | high | G1 gap", "== verify-state: f ==\n", 0),
		fakeCase("ff-root-flag", "STALE | ", "== verify-state: RESEARCH-STATE.md (target: t) ==\n   FAIL   boom\n", 1, "--root"),
	)

	// --- 5. the queue (kit #1614) -----------------------------------------------------------------------------
	qrows := []string{row("high", "G1 first gap", "pending"), row("medium", "G2 second gap", "pending"), row("low", "G3 third gap", "pending")}
	q := func(name, want, hdr string, rows ...string) s4Scenario {
		if len(rows) == 0 {
			rows = qrows
		}
		return n4(name, want, st4(hdr, "0", -1, "", rows...), nil, "--queue")
	}
	add(
		q("queue-head-is-the-first-item", "NEXT | low | G3 third gap", "next_session_queue: G3, G1, G2"),
		q("queue-of-two", "NEXT | medium | G2 second gap", "next_session_queue: G2, G3"),
		q("queue-single-item", "NEXT | low | G3 third gap", "next_session_queue: G3"),
		q("queue-list-marker-form", "NEXT | medium | G2 second gap", "- next_session_queue: G2"),
		q("queue-last-item-is-the-only-pending", "NEXT | low | G3 third gap", "next_session_queue: G1, G2, G3", row("high", "G1 first gap", "covered"), row("medium", "G2 second gap", "done"), row("low", "G3 third gap", "pending")),
		q("queue-middle-item-after-a-done-head", "NEXT | medium | G2 second gap", "next_session_queue: G1, G2, G3", row("high", "G1 first gap", "covered"), row("medium", "G2 second gap", "pending"), row("low", "G3 third gap", "pending")),
		q("queue-id-boundary-g1-is-not-g10-or-g1-b", "NEXT | low | G1 real", "next_session_queue: G1", row("high", "G10 ten", "pending"), row("medium", "G1-b sub", "pending"), row("low", "G1 real", "pending")),
		q("queue-blocked-queued-gap-skipped", "NEXT | medium | G2 second gap", "next_session_queue: G1, G2", row("high", "G1 first gap", "blocked (requires-hardware)"), row("medium", "G2 second gap", "pending")),
		n4("queue-pending-in-blocked-section-skipped", "NEXT | medium | G2 second gap",
			blk(st4("next_session_queue: G1, G2", "0", 1, blockHdr+"- G1 first gap — needs: hardware\n", row("high", "G1 first gap", "pending"), row("medium", "G2 second gap", "pending"))), nil, "--queue"),
		n4("queue-no-flag-priority-order-and-silent", "NEXT | high | G1 first gap", st4("next_session_queue: G3, G1, G2", "0", -1, "", qrows...), nil),
		q("queue-absent", "NEXT | high | G1 first gap", ""),
		q("queue-declared-empty", "NEXT | high | G1 first gap", "next_session_queue:"),
		q("queue-none-is-empty", "NEXT | high | G1 first gap", "next_session_queue: none"),
		q("queue-none-uppercase-is-empty", "NEXT | high | G1 first gap", "next_session_queue: NONE"),
		q("queue-empty-brackets", "NEXT | high | G1 first gap", "next_session_queue: []"),
		q("queue-all-done-is-exhausted", "NEXT | low | G3 third gap", "next_session_queue: G1, G2", row("high", "G1 first gap", "covered"), row("medium", "G2 second gap", "done"), row("low", "G3 third gap", "pending")),
		q("queue-unknown-id-warns-next-served", "NEXT | medium | G2 second gap", "next_session_queue: G9, G2"),
		q("queue-only-unknown-is-exhausted", "NEXT | high | G1 first gap", "next_session_queue: G9"),
		q("queue-malformed-empty-item", "NEXT | high | G1 first gap", "next_session_queue: G1, , G2"),
		q("queue-malformed-prose-item", "NEXT | high | G1 first gap", "next_session_queue: G2 then G3"),
		q("queue-malformed-trailing-comma", "NEXT | high | G1 first gap", "next_session_queue: G1, G2,"),
		q("queue-malformed-leading-comma", "NEXT | high | G1 first gap", "next_session_queue: ,G1"),
		q("queue-malformed-declared-twice", "NEXT | high | G1 first gap", "next_session_queue: G3\nnext_session_queue: G2"),
		q("queue-duplicate-id-warns-first-kept", "NEXT | low | G3 third gap", "next_session_queue: G3, G3, G1"),
		q("queue-prose-only-header", "NEXT | high | G1 first gap", "The next session queue is G3 then G1."),
		q("queue-prose-only-mixed-case-and-separators", "NEXT | high | G1 first gap", "Next-Session_Queue: pending decision"),
		n4("queue-field-below-the-header-is-not-read", "NEXT | high | G1 first gap", st4("", "0", -1, "", qrows...)+"\nnext_session_queue: G3\n", nil, "--queue"),
		q("queue-template-comment-is-not-a-declaration", "NEXT | high | G1 first gap", "<!-- OPTIONAL: add a line\n     `next_session_queue: <gap-id>, ...` starting at column 0\n     (next session queue) -->"),
		q("queue-single-line-comment-is-skipped", "NEXT | high | G1 first gap", "<!-- next_session_queue: G3 -->"),
		q("queue-indented-mention-is-not-a-declaration", "NEXT | high | G1 first gap", "    next_session_queue: G3"),
		q("queue-list-marker-without-space-is-not-a-declaration", "NEXT | high | G1 first gap", "-next_session_queue: G3"),
		q("queue-value-whitespace-is-trimmed", "NEXT | low | G3 third gap", "next_session_queue:    G3   ,   G1   "),
		q("queue-tab-padded-value", "NEXT | low | G3 third gap", "next_session_queue:\tG3\t,\tG1\t"),
		q("queue-id-with-dots-and-underscores", "NEXT | high | G1.2_x first", "next_session_queue: G1.2_x", row("high", "G1.2_x first", "pending")),
		q("queue-id-must-start-alphanumeric", "NEXT | high | G1 first gap", "next_session_queue: _G1"),
		q("queue-id-with-a-glob-char", "NEXT | high | G1 first gap", "next_session_queue: G*"),
		q("queue-queued-id-matches-a-bold-gap-cell", "NEXT | high | **G1 bold** first", "next_session_queue: G1", row("high", "**G1 bold** first", "pending")),
		q("queue-queued-id-matches-a-backtick-gap-cell", "NEXT | high | `G1` first", "next_session_queue: G1", row("high", "`G1` first", "pending")),
		q("queue-queued-id-matches-a-struck-gap-cell", "NEXT | low | G2 later", "next_session_queue: G1, G2", row("high", "~~G1 old~~", "pending"), row("low", "G2 later", "pending")),
		q("queue-ambiguous-id-a-servable-row-wins", "NEXT | low | G1 second", "next_session_queue: G1", row("high", "G1 first", "covered"), row("low", "G1 second", "pending")),
		q("queue-ambiguous-id-all-closed", "NEXT | low | G2 later", "next_session_queue: G1", row("high", "G1 first", "covered"), row("medium", "G1 again", "done"), row("low", "G2 later", "pending")),
		q("queue-in-progress-queued-gap-is-skipped", "NEXT | low | G2 later", "next_session_queue: G9, G2", row("high", "G1 first gap", "pending"), row("medium", "G9 half done", "in-progress"), row("low", "G2 later", "pending")),
		n4("queue-requires-execution-queued-gap-is-blocked-class", "NEXT | low | G2 later", strings.NewReplacer("requires_execution_open: 0", "requires_execution_open: 1", "requires-execution**: 0", "requires-execution**: 1").Replace(st4("next_session_queue: G9, G2", "0", -1, "", row("high", "G1 first gap", "pending"), row("medium", "G9 hw", "requires-execution"), row("low", "G2 later", "pending"))), nil, "--queue"),
		q("queue-blocked-prefix-status-is-blocked-class", "NEXT | low | G2 later", "next_session_queue: G9, G2", row("high", "G1 first gap", "pending"), row("medium", "G9 stuck", "blocked-on-hw"), row("low", "G2 later", "pending")),
	)
	// the closed-class queue rows: struck priority, struck name, closed deferred, open deferred, in progress, em-dash
	crows := []string{row("high", "G1 first gap", "pending"), row("~~high~~", "G5 struck-priority gap", "~~covered~~"), row("high", "~~G6 struck-name gap~~", "covered"),
		row("deferred", "G7 parked closed", "✅ done"), row("deferred", "G8 parked open", "parked"), row("medium", "G9 half done", "in-progress"), row("—", "G10 emdash closed", "covered")}
	add(q("queue-closed-class-rows-are-known", "NEXT | high | G1 first gap", "next_session_queue: G5, G6, G7, G8, G9, G10", crows...))
	for _, k := range []string{"G5", "G6", "G7", "G8", "G9", "G10"} {
		add(q("queue-closed-class-"+k+"-is-known", "NEXT | high | G1 first gap", "next_session_queue: "+k, crows...))
	}
	add(
		m4("queue-five-column-open-deferred-is-known", "NEXT | high | G1", files{stateRel: "# Q5\n\nnext_session_queue: G8\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n\n" + h5 + "\n| high | G1 | first gap | web | pending |\n| deferred | G8 | parked thing | web | parked |\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 1\n"}, "--queue"),
		m4("queue-scoped-focus", "NEXT | low | G3 third gap", files{"corpus/RESEARCH-STATE.md": st4("", "0", -1, "", qrows...), "corpus/RESEARCH-STATE-act.md": st4("next_session_queue: G3", "0", -1, "", qrows...)}, "--focus", "act", "--queue"),
		m4("queue-focus-file-without-a-queue", "NEXT | high | G1 first gap", files{"corpus/RESEARCH-STATE-act.md": st4("", "0", -1, "", qrows...)}, "--queue"),
		m4("queue-aggregate-serves-the-first-file-in-sort-order", "NEXT | medium | G2 second gap", files{"corpus/RESEARCH-STATE.md": st4("next_session_queue: G3", "0", -1, "", qrows...), "corpus/RESEARCH-STATE-act.md": st4("next_session_queue: G2", "0", -1, "", qrows...)}, "--queue"),
		m4("queue-aggregate-falls-through-to-the-next-file", "NEXT | medium | G2 second gap", files{"corpus/RESEARCH-STATE-act.md": st4("next_session_queue: G1", "0", 0, "", row("high", "G1 first gap", "covered")), "corpus/RESEARCH-STATE.md": st4("next_session_queue: G2", "0", -1, "", qrows...)}, "--queue"),
		m4("queue-never-bypasses-stale", "STALE | ", files{stateRel: st4("next_session_queue: G3", "0", 0, "", qrows...)}, "--queue"),
		m4("queue-never-bypasses-retro-due", "RETRO-DUE | 11 blocks", files{stateRel: st4("next_session_queue: G3", "11", -1, "", qrows...)}, "--queue"),
		m4("queue-exhausted-stop-after-the-fallback", stopLine, files{stateRel: st4("next_session_queue: G1", "0", 0, "", row("high", "G1 first gap", "covered"))}, "--queue"),
		m4("queue-scoped-stop-after-the-fallback", stopLine, files{stateRel: st4("next_session_queue: G1", "0", 0, "", row("high", "G1 first gap", "covered"))}, "--root", "--queue"),
	)

	// --- 6. the exhausted STOP and its [backlog-unreadable] qualifier (kit #1959) ------------------------------
	canon, near := "## Gap-backlog (prioritized)", "## Gap backlog"
	ur := func(heading string, rows ...string) string {
		return strings.Replace(st4("", "0", 0, "", rows...), canon, heading, 1)
	}
	cov := row("high", "done gap", "covered")
	u1, u2, u3 := "| 1 | numbered one | web | pending |", "| 2 | numbered two | web | pending |", "| P0 | numbered three | web | pending |"
	const bare = stopLine
	add(
		n4("ur-clean-canonical-backlog-is-a-bare-stop", bare, ur(canon, cov), nil),
		n4("ur-one-unread-row", bare+" [backlog-unreadable: 1 rows]", ur(near, cov, u1), nil),
		n4("ur-three-unread-rows", bare+" [backlog-unreadable: 3 rows]", ur(near, cov, u1, u2, u3), nil),
		n4("ur-root-flag-counts-the-picked-file", bare+" [backlog-unreadable: 1 rows]", ur(near, cov, u1), nil, "--root"),
		m4("ur-multi-whole-corpus-sums-the-walked-files", bare+" [backlog-unreadable: 2 rows]", files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(near, cov, u1, u2), "corpus/RESEARCH-STATE-good.md": ur(canon, cov)}),
		m4("ur-multi-focus-bad-counts-only-the-pick", bare+" [backlog-unreadable: 2 rows]", files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(near, cov, u1, u2), "corpus/RESEARCH-STATE-good.md": ur(canon, cov)}, "--focus", "bad"),
		m4("ur-multi-focus-good-stays-bare", bare, files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(near, cov, u1, u2), "corpus/RESEARCH-STATE-good.md": ur(canon, cov)}, "--focus", "good"),
		m4("ur-multi-root-stays-bare", bare, files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(near, cov, u1, u2), "corpus/RESEARCH-STATE-good.md": ur(canon, cov)}, "--root"),
		m4("ur-two-files-sum-1-plus-2", bare+" [backlog-unreadable: 3 rows]", files{"corpus/RESEARCH-STATE.md": ur(near, cov, u1), "corpus/RESEARCH-STATE-bad.md": ur(near, cov, u1, u2)}),
		m4("ur-paused-focus-rows-still-qualify", bare+" [backlog-unreadable: 1 rows]", files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-old.md": ur(near, cov, u1), "corpus/FOCUSES.md": focusRows("old", "paused")}),
		m4("ur-paused-focus-with-an-open-gap-no-active-focus", "STOP | no active focus (1 declared stopped/paused in FOCUSES.md with open gaps) [backlog-unreadable: 1 rows]", files{
			"corpus/RESEARCH-STATE.md":     ur(canon, cov),
			"corpus/RESEARCH-STATE-old.md": strings.NewReplacer("investigable_open: 0", "investigable_open: 1", "investigable**: 0", "investigable**: 1").Replace(ur(near, cov, u1, row("high", "open gap", "pending"))),
			"corpus/FOCUSES.md":            focusRows("old", "paused")}),
		m4("ur-stopped-focus-with-an-open-gap-no-active-focus", "STOP | no active focus (1 declared stopped/paused in FOCUSES.md with open gaps)", files{
			"corpus/RESEARCH-STATE-old.md": strings.NewReplacer("investigable_open: 0", "investigable_open: 1", "investigable**: 0", "investigable**: 1").Replace(ur(canon, cov, row("high", "open gap", "pending"))),
			"corpus/FOCUSES.md":            focusRows("old", "stopped")}),
		m4("ur-two-skipped-focuses-with-open-gaps-counted", "STOP | no active focus (2 declared stopped/paused in FOCUSES.md with open gaps)", files{
			"corpus/RESEARCH-STATE-a.md": strings.NewReplacer("investigable_open: 0", "investigable_open: 1", "investigable**: 0", "investigable**: 1").Replace(ur(canon, cov, row("high", "open a", "pending"))),
			"corpus/RESEARCH-STATE-b.md": strings.NewReplacer("investigable_open: 0", "investigable_open: 1", "investigable**: 0", "investigable**: 1").Replace(ur(canon, cov, row("high", "open b", "pending"))),
			"corpus/FOCUSES.md":          focusRows("a", "stopped", "b", "paused")}),
		m4("ur-skipped-focus-without-open-gaps-is-a-plain-stop", bare, files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-old.md": ur(canon, cov), "corpus/FOCUSES.md": focusRows("old", "stopped")}),
		n4("ur-next-verdict-carries-no-qualifier", "NEXT | high | real gap", strings.NewReplacer("investigable_open: 0", "investigable_open: 1", "investigable**: 0", "investigable**: 1").Replace(ur(near, cov, u1, row("high", "real gap", "pending"))), nil),
		n4("ur-emit-token-refuses-the-qualified-stop", "return-token: unavailable (STOP carries [backlog-unreadable: N rows]", ur(near, cov, u1), nil, "--emit-token"),
		n4("ur-emit-token-maps-the-clean-stop", "return-token: ", ur(canon, cov), nil, "--emit-token"),
	)
	// an unreadable paused focus file is unverified, never zero (kit #1959 W2)
	unr := m4("ur-unreadable-paused-file-is-unverified", bare+" [backlog-unreadable: unverified]", files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(canon, cov), "corpus/FOCUSES.md": focusRows("bad", "paused")})
	unr.unreadable, unr.needsUser = []string{"corpus/RESEARCH-STATE-bad.md"}, true
	unr2 := m4("ur-unreadable-paused-file-emit-token", "return-token: unavailable (", files{"corpus/RESEARCH-STATE.md": ur(canon, cov), "corpus/RESEARCH-STATE-bad.md": ur(canon, cov), "corpus/FOCUSES.md": focusRows("bad", "paused")}, "--emit-token")
	unr2.unreadable, unr2.needsUser = []string{"corpus/RESEARCH-STATE-bad.md"}, true
	add(unr, unr2)

	// --- 7. the paused/stopped skip and the aggregate walk ---------------------------------------------------
	add(
		m4("walk-skipped-first-file-serves-the-second", "NEXT | high | the beta gap", files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "pending", 1, "0"), "corpus/RESEARCH-STATE-beta.md": one("beta", "pending", 1, "0"), "corpus/FOCUSES.md": focusRows("alpha", "stopped", "beta", "open")}),
		m4("walk-first-active-file-wins", "NEXT | high | the alpha gap", files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "pending", 1, "0"), "corpus/RESEARCH-STATE-beta.md": one("beta", "pending", 1, "0")}),
		m4("walk-exhausted-first-falls-to-the-second", "NEXT | high | the beta gap", files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "covered", 0, "0"), "corpus/RESEARCH-STATE-beta.md": one("beta", "pending", 1, "0")}),
		m4("walk-all-exhausted", stopLine, files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "covered", 0, "0"), "corpus/RESEARCH-STATE-beta.md": one("beta", "covered", 0, "0")}),
		m4("walk-focuses-row-missing-warns-once", "NEXT | high | the alpha gap", files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "pending", 1, "0"), "corpus/RESEARCH-STATE-beta.md": one("beta", "pending", 1, "0"), "corpus/FOCUSES.md": focusRows("beta", "open")}),
		m4("walk-skip-info-line-names-the-slug", stopLine, files{"corpus/RESEARCH-STATE.md": one("root", "covered", 0, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "covered", 0, "0"), "corpus/FOCUSES.md": focusRows("old", "paused")}),
		m4("walk-root-slug-of-a-skipped-root", "NEXT | high | the act gap", files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "pending", 1, "0"), "corpus/FOCUSES.md": "| focus | status |\n|---|---|\n| root | stopped |\n| act | open |\n"}),
		m4("walk-scoped-pick-is-not-skipped-when-stopped", "NEXT | high | the old gap", files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "pending", 1, "0"), "corpus/FOCUSES.md": focusRows("old", "stopped")}, "--focus", "old"),
		m4("walk-scoped-stop-with-the-qualifier-of-the-pick-only", stopLine, files{"corpus/RESEARCH-STATE.md": one("root", "covered", 0, "0"), "corpus/RESEARCH-STATE-old.md": one("old", "pending", 1, "0")}, "--root"),
		m4("walk-split-layout-subdirectory", "NEXT | high | the sub gap", files{"corpus/a/RESEARCH-STATE-sub.md": one("sub", "pending", 1, "0"), "corpus/b/RESEARCH-STATE-other.md": one("other", "covered", 0, "0")}),
		m4("walk-bootstrap-is-answered-before-the-gate", "BOOTSTRAP | no RESEARCH-STATE under ", files{"corpus/notes.md": "x\n"}),
		m4("walk-emit-token-next", "NEXT | high | the root gap", files{stateRel: one("root", "pending", 1, "0")}, "--emit-token"),
		m4("walk-emit-token-retro-due-is-unavailable", "RETRO-DUE | 12 blocks", files{stateRel: one("root", "pending", 1, "12")}, "--emit-token"),
		m4("walk-emit-token-stale-is-unavailable", "STALE | ", files{stateRel: one("root", "pending", 0, "0")}, "--emit-token"),
		m4("walk-emit-token-stop-maps-the-campaign-token", stopLine, files{stateRel: one("root", "covered", 0, "0")}, "--emit-token"),
		m4("walk-emit-token-stop-over-two-files-is-unavailable", stopLine, files{"corpus/RESEARCH-STATE.md": one("root", "covered", 0, "0"), "corpus/RESEARCH-STATE-act.md": one("act", "covered", 0, "0")}, "--emit-token"),
		m4("walk-emit-token-queue", "NEXT | low | G3 third gap", files{stateRel: st4("next_session_queue: G3", "0", -1, "", qrows...)}, "--queue", "--emit-token"),
	)
	return scs
}
