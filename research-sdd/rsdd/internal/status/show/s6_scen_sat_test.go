package show

// The saturation group: the iteration-history parser (iter_gaps_rows) and the three-state honesty of
// saturation_line (#420), one scenario per recognised form and per branch of the verdict.

// itTable is a "## Iteration history" section with the given header line and rows.
func itTable(header string, rows ...string) string {
	return ln(append([]string{"\n## Iteration history", "", header, "|---|---|---|---|"}, rows...)...)
}

const itHdr = "| Iter | Date | New gaps | Notes |"

// it is one data row: iteration index, New-gaps cell.
func it(idx, gaps string) string { return "| " + idx + " | 2026-01-01 | " + gaps + " | n |" }

func s6Saturation() []s6Scenario {
	var scs []s6Scenario
	pend := row("high", "the root gap", "pending")
	sat := func(name, want, tail string) {
		scs = append(scs, os6(name, "  saturation      : "+want, st6(1, tail, pend), nil, nil))
	}
	tbl := func(rows ...string) string { return itTable(itHdr, rows...) }
	sat("s-no-section", "(no iteration history)", "")
	sat("s-heading-only-anywhere-in-the-file-counts", "insufficient history (0 iterations)", "\nSee ## Iteration history below.\n\n## Iteration history\n\n")
	sat("s-heading-text-in-prose-is-found-with-no-table", "insufficient history (0 iterations)", "\nsee the ## Iteration history notes\n")
	sat("s-no-new-gaps-column", "no New-gaps column (header:  Iter | Date | Notes )", itTable("| Iter | Date | Notes |", it("1", "3")))
	sat("s-no-new-gaps-column-header-keeps-escaped-pipe", "no New-gaps column (header:  Iter | x | Date | Notes )", itTable(`| Iter \| x | Date | Notes |`, it("1", "3")))
	sat("s-spanish-header-nuevos-gaps", "active (5 new gaps in last 3 iter)", itTable("| It | Fecha | Nuevos gaps |", "| 1 | d | 1 |", "| 2 | d | 2 |", "| 3 | d | 2 |"))
	sat("s-header-match-is-case-insensitive", "active (3 new gaps in last 3 iter)", itTable("| It | NEW GAPS |", "| 1 | 1 |", "| 2 | 1 |", "| 3 | 1 |"))
	sat("s-column-chosen-by-name-not-position", "SATURATED (review) — last 3 iterations netted 0 new gaps", itTable("| Iter | New gaps | Total |", "| 1 | 0 | 9 |", "| 2 | 0 | 9 |", "| 3 | 0 | 9 |"))
	sat("s-header-without-rows", "insufficient history (0 iterations)", tbl())
	sat("s-one-iteration", "insufficient history (1 iterations)", tbl(it("1", "3")))
	sat("s-two-iterations", "insufficient history (2 iterations)", tbl(it("1", "3"), it("2", "0")))
	sat("s-three-iterations-active", "active (4 new gaps in last 3 iter)", tbl(it("1", "1"), it("2", "1"), it("3", "2")))
	sat("s-three-iterations-saturated", "SATURATED (review) — last 3 iterations netted 0 new gaps", tbl(it("1", "0"), it("2", "0"), it("3", "0")))
	sat("s-window-is-the-last-three", "SATURATED (review) — last 3 iterations netted 0 new gaps", tbl(it("1", "9"), it("2", "0"), it("3", "0"), it("4", "0")))
	sat("s-window-follows-the-index-not-the-file-order", "active (1 new gaps in last 3 iter)", tbl(it("4", "0"), it("1", "9"), it("3", "0"), it("2", "0"), it("5", "1")))
	sat("s-index-order-is-numeric", "active (1 new gaps in last 3 iter)", tbl(it("9", "0"), it("10", "1"), it("8", "0"), it("11", "0")))
	sat("s-index-with-leading-zeros", "active (2 new gaps in last 3 iter)", tbl(it("007", "0"), it("08", "2"), it("009", "0")))
	sat("s-it-prefix-on-the-index", "active (1 new gaps in last 3 iter)", tbl(it("it.1", "0"), it("it.2", "1"), it("it.3", "0")))
	sat("s-index-prefix-is-case-sensitive", "insufficient history (0 iterations)  [3 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("It.1", "0"), it("It.2", "1"), it("It.3", "0")))
	sat("s-index-with-a-suffix", "active (1 new gaps in last 3 iter)", tbl(it("1a", "0"), it("2b", "1"), it("3-c", "0")))
	sat("s-duplicate-index-ties-break-on-the-whole-line", "active (3 new gaps in last 3 iter)", tbl(it("1", "2"), it("1", "1"), it("1", "0")))
	sat("s-duplicate-index-bad-before-ok", "unreadable window — 1 of last 3 rows unrecognised (forms: zz)", tbl(it("1", "0"), it("1", "zz"), it("1", "1")))
	sat("s-leading-plus-and-words", "active (6 new gaps in last 3 iter)", tbl(it("1", "+1"), it("2", "2 new"), it("3", "3 new (focus STOP)")))
	sat("s-seeded-and-trailing-prose", "active (4 new gaps in last 3 iter)", tbl(it("1", "2 seeded"), it("2", "1 x"), it("3", "1")))
	sat("s-none-family", "SATURATED (review) — last 3 iterations netted 0 new gaps", tbl(it("1", "none"), it("2", "None net-new · x"), it("3", "none new — y")))
	sat("s-none-prefix-is-a-prefix", "SATURATED (review) — last 3 iterations netted 0 new gaps", tbl(it("1", "nonexistent"), it("2", "NONE"), it("3", "ninguno")))
	sat("s-spanish-none", "SATURATED (review) — last 3 iterations netted 0 new gaps", tbl(it("1", "ninguna"), it("2", "Ningún nuevo"), it("3", "ningun")))
	sat("s-bold-number-is-unreadable", "unreadable window — 1 of last 3 rows unrecognised (forms: **3**)", tbl(it("1", "0"), it("2", "0"), it("3", "**3**")))
	sat("s-empty-cell-is-unreadable", "unreadable window — 1 of last 3 rows unrecognised (forms: (empty))", tbl(it("1", "0"), it("2", "0"), "| 3 | d |  | n |"))
	sat("s-row-shorter-than-the-column-is-empty", "unreadable window — 1 of last 3 rows unrecognised (forms: (empty))", itTable("| It | D | N | New gaps |", "| 1 | d | n | 0 |", "| 2 | d | n | 0 |", "| 3 | d |"))
	sat("s-gap-id-list-is-unreadable", "unreadable window — 2 of last 3 rows unrecognised (forms: B754-G1/G2,IC1–IC4 seeded)", tbl(it("1", "0"), it("2", "B754-G1/G2"), it("3", "IC1–IC4 seeded")))
	sat("s-window-forms-keep-two-distinct", "unreadable window — 3 of last 3 rows unrecognised (forms: a,b)", tbl(it("1", "a"), it("2", "b"), it("3", "a")))
	sat("s-window-forms-dedupe-the-same-cell", "unreadable window — 2 of last 3 rows unrecognised (forms: a)", tbl(it("1", "a"), it("2", "a"), it("3", "1")))
	sat("s-older-unreadable-row-warns", "active (2 new gaps in last 3 iter)  [WARN: 1 of 4 rows unreadable (forms: prose)]", tbl(it("1", "prose"), it("2", "1"), it("3", "1"), it("4", "0")))
	sat("s-older-unreadable-rows-keep-two-forms", "active (1 new gaps in last 3 iter)  [WARN: 3 of 6 rows unreadable (forms: x,y)]", tbl(it("1", "x"), it("2", "y"), it("3", "x"), it("4", "1"), it("5", "0"), it("6", "0")))
	sat("s-unreadable-row-outside-the-window-cannot-rescue", "unreadable window — 1 of last 3 rows unrecognised (forms: zz)", tbl(it("1", "1"), it("2", "0"), it("3", "zz"), it("4", "0")))
	sat("s-unreadable-two-iterations-reports-the-window", "unreadable window — 1 of last 2 rows unrecognised (forms: zz)", tbl(it("1", "0"), it("2", "zz")))
	sat("s-struct-rows-excluded", "active (1 new gaps in last 3 iter)  [2 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("bootstrap", "5"), it("1", "0"), it("2", "1"), it("reopen", "0"), it("3", "0")))
	sat("s-struct-rows-only", "insufficient history (0 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("bootstrap", "0")))
	sat("s-latest-unnumbered-row-seeded", "insufficient history (1 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]  · latest unnumbered row seeded 4 gaps — not yet an iteration", tbl(it("1", "0"), it("synthesis", "4")))
	sat("s-latest-unnumbered-row-with-zero-gaps-is-not-a-seed", "insufficient history (1 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "0"), it("synthesis", "none")))
	sat("s-latest-unnumbered-row-unreadable-is-not-a-seed", "insufficient history (1 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "0"), it("synthesis", "prose")))
	sat("s-seed-note-only-when-the-last-row-is-unnumbered", "insufficient history (2 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "0"), it("synthesis", "4"), it("2", "0")))
	sat("s-unreadable-struct-row-counts-in-the-total", "unreadable window — 1 of last 3 rows unrecognised (forms: prose)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "1"), it("2", "0"), it("3", "0"), it("4", "prose"), it("bootstrap", "prose")))
	sat("s-warn-on-saturated-too", "SATURATED (review) — last 3 iterations netted 0 new gaps  [WARN: 1 of 4 rows unreadable (forms: prose)]", tbl(it("1", "prose"), it("2", "0"), it("3", "0"), it("4", "0")))
	sat("s-placeholder-rows-are-skipped", "insufficient history (1 iterations)", tbl("| <n> | <date> | <gaps> | <note> |", it("1", "0")))
	sat("s-placeholder-in-any-cell-skips-the-row", "insufficient history (1 iterations)", tbl(it("1", "0"), "| 2 | <date> | 1 | n |"))
	sat("s-html-comment-lines-are-skipped", "active (1 new gaps in last 3 iter)", tbl("<!-- | 1 | d | 9 | n | -->", it("1", "0"), "| 2 | d | 1 | <!-- x --> |", it("2", "1"), it("3", "0")))
	sat("s-separator-with-colons-is-skipped", "active (1 new gaps in last 3 iter)", itTable("| It | New gaps |", "| :--- | ---: |", "| 1 | 0 |", "| 2 | 1 |", "| 3 | 0 |"))
	sat("s-escaped-pipe-keeps-the-columns", "active (1 new gaps in last 3 iter)", itTable("| It | Note | New gaps |", `| 1 | a \| b | 0 |`, `| 2 | a \| b | 1 |`, `| 3 | c | 0 |`))
	sat("s-rows-without-outer-pipes", "active (1 new gaps in last 3 iter)", itTable("It | New gaps", "1 | 0", "2 | 1", "3 | 0"))
	sat("s-non-table-lines-are-skipped", "active (1 new gaps in last 3 iter)", ln("\n## Iteration history", "", "prose without pipes", itHdr, "|---|---|---|---|", it("1", "0"), "more prose", it("2", "1"), it("3", "0")))
	sat("s-only-the-section-is-read", "insufficient history (0 iterations)", ln("\n## Iteration history", "", itHdr, "|---|---|---|---|", "", "## Later", "", it("1", "0"), it("2", "0"), it("3", "0")))
	sat("s-heading-prefix-matches-the-section", "active (1 new gaps in last 3 iter)", ln("\n## Iteration history (newest last)", "", itHdr, "|---|---|---|---|", it("1", "0"), it("2", "1"), it("3", "0")))
	sat("s-leading-spaces-in-cells-and-rows", "active (3 new gaps in last 3 iter)", itTable("  |  It  |  New gaps  |  ", "  |  1  |  1  |", "\t|\t2\t|\t1\t|", "|3|1|"))
	sat("s-first-matching-column-wins", "active (3 new gaps in last 3 iter)", itTable("| It | New gaps | Nuevos gaps |", "| 1 | 1 | 9 |", "| 2 | 1 | 9 |", "| 3 | 1 | 9 |"))
	sat("s-unterminated-final-row", "active (1 new gaps in last 3 iter)", "\n## Iteration history\n\n"+itHdr+"\n|---|---|---|---|\n"+it("1", "0")+"\n"+it("2", "1")+"\n"+it("3", "0"))
	sat("s-large-counts", "active (3000000 new gaps in last 3 iter)", tbl(it("1", "1000000"), it("2", "1000000"), it("3", "1000000")))
	sat("s-gaps-with-leading-zeros", "active (12 new gaps in last 3 iter)", tbl(it("1", "007"), it("2", "0"), it("3", "+05")))
	sat("s-unnumbered-row-sorts-by-its-position", "active (1 new gaps in last 3 iter)  [WARN: 2 of 5 rows unreadable (forms: i1,s)]  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("3", "0"), it("4", "1"), it("5", "0"), it("1", "i1"), it("synthesis", "s")))
	sat("s-warn-total-counts-numbered-and-unnumbered-rows", "active (1 new gaps in last 3 iter)  [WARN: 1 of 6 rows unreadable (forms: x)]  [2 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "x"), it("2", "1"), it("3", "0"), it("4", "0"), it("bootstrap", "2"), it("reopen", "none")))
	sat("s-angle-brackets-alone-are-a-placeholder", "insufficient history (1 iterations)", tbl(it("1", "0"), "| <> | d | 5 | n |"))
	sat("s-a-lone-angle-bracket-is-not-a-placeholder", "insufficient history (1 iterations)  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]  · latest unnumbered row seeded 5 gaps — not yet an iteration", tbl(it("1", "0"), "| < | d | 5 | n |"))
	sat("s-latest-unnumbered-row-is-the-last-one", "insufficient history (1 iterations)  [2 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]  · latest unnumbered row seeded 7 gaps — not yet an iteration", tbl(it("1", "0"), it("bootstrap", "3"), it("synthesis", "7")))
	sat("s-unnumbered-row-keeps-its-place-among-the-forms", "active (1 new gaps in last 3 iter)  [WARN: 2 of 6 rows unreadable (forms: aa,bb)]  [1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", tbl(it("1", "0"), it("synthesis", "aa"), it("3", "bb"), it("4", "0"), it("5", "0"), it("6", "1")))
	return scs
}
