package show

import "strings"

// Group 4: the document-cycle outline: the detection, the status vocabulary, the three table states, the cell
// grammar (escaped pipes, bold, trailing empties) and how the outline's next step meets the gap-centric walk.

// outlineSection is a "## Outline" section holding the table rows.
func outlineSection(rows ...string) string {
	return "\n## Outline\n\n| # | Item | Status |\n|---|---|---|\n" + ln(rows...)
}

// orow is an outline row.
func orow(num, item, status string) string { return "| " + num + " | " + item + " | " + status + " |" }

// docState is a state file of method document-cycle with the given tail (the Outline section).
func docState(tail string, rows ...string) string {
	if len(rows) == 0 {
		rows = []string{row("high", "the root gap", "pending")}
	}
	return envWith(st6(len(rows), tail, rows...), "method: document-cycle")
}

func s7Doc() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	out := "  outline         : "
	next := "  next step       : "
	d := func(name, want string, rows ...string) {
		add(os6(name, want, docState(outlineSection(rows...)), nil, nil))
	}
	d("d-seeded-counts", out+"1/4 covered · drafted=1 · pending=2",
		orow("1", "Intro", "covered"), orow("2", "Body", "drafted"), orow("3", "Tail", "pending"), orow("4", "Extra", "pending"))
	d("d-first-open-row-is-the-next-step", next+"NEXT | outline #2 | Body",
		orow("1", "Intro", "covered"), orow("2", "Body", "drafted"), orow("3", "Tail", "pending"))
	d("d-pending-before-drafted-keeps-table-order", next+"NEXT | outline #2 | Body",
		orow("1", "Intro", "covered"), orow("2", "Body", "pending"), orow("3", "Tail", "drafted"))
	d("d-all-covered-counts", out+"2/2 covered · drafted=0 · pending=0", orow("1", "Intro", "covered"), orow("2", "Body", "covered"))
	d("d-covered-spellings", out+"6/6 covered · drafted=0 · pending=0",
		orow("1", "a", "covered"), orow("2", "b", "done"), orow("3", "c", "closed"), orow("4", "d", "cubierto"), orow("5", "e", "✅"), orow("6", "f", "**Covered**"))
	d("d-status-is-the-first-word", out+"1/2 covered · drafted=1 · pending=0", orow("1", "a", "covered (reviewed)"), orow("2", "b", "drafted (needs review)"))
	d("d-status-is-lowercased", out+"0/1 covered · drafted=1 · pending=0", orow("1", "a", "DRAFTED"))
	d("d-status-bold-marks-are-stripped", out+"0/1 covered · drafted=0 · pending=1", orow("1", "a", "**pending**"))
	d("d-status-leading-bold-then-space", out+"1/1 covered", orow("1", "a", "** covered **"))
	d("d-unrecognised-stays-open", out+"1/3 covered · drafted=0 · pending=1 · unrecognised=1", orow("1", "a", "covered"), orow("2", "b", "wip"), orow("3", "c", "pending"))
	d("d-unrecognised-is-the-next-step", next+"NEXT | outline #1 | a", orow("1", "a", "blocked"), orow("2", "b", "covered"))
	d("d-status-prefix-is-not-the-token", out+"0/1 covered · drafted=0 · pending=0 · unrecognised=1", orow("1", "a", "covered-ish"))
	d("d-bold-item", next+"NEXT | outline #2 | Body", orow("1", "**Intro**", "covered"), orow("2", "**Body**", "pending"))
	d("d-item-keeps-inner-bold", next+"NEXT | outline #1 | a **b** c", orow("1", "a **b** c", "pending"))
	d("d-escaped-pipe-in-the-item", next+"NEXT | outline #1 | a | b", orow("1", `a \| b`, "pending"))
	d("d-double-backslash-before-a-pipe", next+`NEXT | outline #1 | a\| b`, orow("1", `a\\| b`, "pending"))
	d("d-first-cell-must-be-an-integer", out+"0/1 covered · drafted=0 · pending=1", orow("1", "a", "pending"), orow("x", "b", "pending"), orow("2.5", "c", "pending"), orow("", "d", "pending"))
	d("d-two-cell-row-is-not-a-row", out+"(0 rows — the Outline table is empty)", "| 1 | a |")
	d("d-trailing-empty-cells-are-dropped", next+"NEXT | outline #1 | a", "| 1 | a | pending |  |  |")
	d("d-last-cell-is-the-status", next+"NEXT | outline #1 | a", "| 1 | a | note | drafted |")
	d("d-row-without-a-trailing-pipe", next+"NEXT | outline #1 | a", "| 1 | a | pending")
	d("d-row-without-a-leading-pipe-is-ignored", out+"(0 rows — the Outline table is empty)", "1 | a | pending |")
	d("d-indented-row", next+"NEXT | outline #1 | a", "   | 1 | a | pending |")
	d("d-header-and-separator-are-not-rows", out+"(0 rows — the Outline table is empty)")
	d("d-placeholder-row-is-unseeded", out+"(unseeded: only the template placeholder row)", orow("1", "<topic ...>", "pending"))
	d("d-placeholder-next-step-bootstraps", next+"BOOTSTRAP | seed the ## Outline first (document cycle step 1)", orow("1", "<topic ...>", "pending"))
	d("d-placeholder-next-to-real-rows", out+"0/1 covered · drafted=0 · pending=1", orow("1", "<topic ...>", "pending"), orow("2", "real", "pending"))
	d("d-angle-item-needs-both-brackets", out+"0/2 covered · drafted=0 · pending=2", orow("1", "<open", "pending"), orow("2", "close>", "pending"))
	d("d-empty-outline-bootstraps", next+"BOOTSTRAP | seed the ## Outline first (document cycle step 1)")
	add(
		os6("d-crlf-status-is-unrecognised", out+"0/1 covered · drafted=0 · pending=0 · unrecognised=1", strings.ReplaceAll(docState(outlineSection(orow("1", "a", "covered"))), "\n", "\r\n"), nil, nil),
		os6("d-outline-reads-only-its-own-section", out+"(0 rows — the Outline table is empty)", docState(outlineSection()+"\n## Other\n\n"+orow("1", "z", "pending")+"\n"), nil, nil),
		os6("d-heading-suffix-is-allowed", out+"0/1 covered", docState("\n## Outline (draft)\n\n"+orow("1", "a", "pending")+"\n"), nil, nil),
		os6("d-heading-after-another-section", out+"0/1 covered", docState("\n## Notes\n\nx\n"+outlineSection(orow("1", "a", "pending"))), nil, nil),
	)
	gap := row("high", "the root gap", "pending")
	exhausted := row("high", "the root gap", "covered")
	add(
		os6("d-outline-replaces-the-saturation-line", "  saturation      : n/a (method: document-cycle — gap saturation does not apply; the ## Outline decides)", docState(outlineSection(orow("1", "a", "covered")+"\n")), nil, nil),
		os6("d-next-is-final-over-a-gap", next+"NEXT | outline #1 | a", docState(outlineSection(orow("1", "a", "pending")), gap), nil, nil),
		os6("d-bootstrap-is-final-over-a-gap", next+"BOOTSTRAP | seed the ## Outline first", docState(outlineSection(), gap), nil, nil),
		os6("d-stop-yields-to-a-gap-next", next+"NEXT | high | the root gap", docState(outlineSection(orow("1", "a", "covered")), gap), nil, nil),
		os6("d-stop-replaces-the-gap-stop", next+"STOP | outline fully covered (1/1)", docState(outlineSection(orow("1", "a", "covered")), exhausted), nil, nil),
		os6("d-no-heading-says-so", out+"(no ## Outline section — gap-centric verdicts kept)", envWith(st6(1, "", gap), "method: document-cycle"), nil, nil),
		os6("d-no-heading-keeps-the-gap-walk", next+"NEXT | high | the root gap", envWith(st6(1, "", gap), "method: document-cycle"), nil, nil),
		os6("d-no-heading-keeps-the-saturation-line", "  saturation      : insufficient history (1 iterations)", envWith(st6(1, itTable(itHdr, it("1", "0")), gap), "method: document-cycle"), nil, nil),
		os6("d-outline-heading-in-prose-counts", out+"(0 rows — the Outline table is empty)", docState("\n## Outlines of work\n\nprose\n"), nil, nil),
		os6("d-method-must-be-exact", "  saturation      :", envWith(st6(1, outlineSection(orow("1", "a", "pending")), gap), "method: document-cycle-external"), nil, nil),
		os6("d-method-other-prints-no-outline-line", "  contradictions  : (no ledger)", envWith(st6(1, outlineSection(orow("1", "a", "pending")), gap), "method: sweep"), nil, nil),
		os6("d-first-method-key-wins", "  contradictions  : (no ledger)", envWith(docState(outlineSection(orow("1", "a", "pending"))), "method: other"), nil, nil),
		ws6("d-two-state-files-keep-the-gap-report", next+"NEXT | high | the act gap", twoFocus(docState(outlineSection(orow("1", "a", "pending")), exhausted), one("act", "pending", 1, "0"), nil), nil),
		ws6("d-focus-flag-with-two-states-keeps-the-gap-report", "  saturation      :", twoFocus(docState(outlineSection(orow("1", "a", "pending")), gap), one("act", "pending", 1, "0"), nil), nil, "--focus", "act"),
		os6("d-stale-document-state-is-not-special", out+"0/1 covered", docState(outlineSection(orow("1", "a", "pending"))), nil, nil),
	)
	return scs
}
