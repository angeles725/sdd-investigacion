package show

import "strings"

// The S2 scenario table: backlog_rows / deferred_scan / the counters over crafted state files, and the envelope,
// section and FOCUSES readers. The cases that the toolbelt suites named in issue #2549 pin (-deferred-populations,
// -retyped, -inplace-blocked, and the counter and unknown-priority groups of the main suite) are reproduced here
// as state files; the rest are the branches of the awk programs.

// ln joins lines and ends the text with a newline.
func ln(l ...string) string { return strings.Join(l, "\n") + "\n" }

const (
	h4  = "| Priority | Gap | Artifact | Status |\n|---|---|---|---|"
	h5  = "| Priority | ID | Gap | Artifact | Status |\n|---|---|---|---|---|"
	h5s = "| Priority | Gap | Scope | Where | Status |\n|---|---|---|---|---|"
)

// backlogBattery is the op list run over every backlog scenario: both parses, every counter derived from them.
func backlogBattery() []op {
	return []op{
		o("backlog_rows"), o("backlog_rows", "0"), o("backlog_rows", "1"),
		o("deferred_scan", "0"), o("deferred_scan", "1"), o("count_deferred"),
		o("count_investigable"), o("count_retyped_in_table"), o("count_requires_execution"),
		o("count_all_known_gaps"), o("count_uncounted_rows"), o("__inplace"),
	}
}

func bl(name, state string) s2Scenario {
	return s2Scenario{name: name, state: state, ops: backlogBattery()}
}

func backlogScenarios() []s2Scenario {
	pend := "| high | live gap | web | pending |"
	done := "| low | done gap | web | ✅ covered |"
	scs := []s2Scenario{
		bl("bl-empty", ""),
		bl("bl-no-backlog", ln("# T", "", "prose with a | pipe", "## Notes", "nothing")),
		bl("bl-basic4", ln("## Gap-backlog (prioritized)", "", h4, pend, "| medium | m gap | web | **pending** (note) |", done, "| low | struck | web | ~~dropped~~ |", "| low | ~~G9~~ | web | pending |")),
		bl("bl-basic5", ln("## Gap-backlog", h5, "| high | B1-G1 | a | x | pending |", "| medium | B1-G2 | b | x | **requires-execution** |", "| low | B1-G3 | c | x | blocked (requires-hw) |")),
		bl("bl-uppercase-priority", ln("## Gap-backlog", h4, "| HIGH | g1 | x | PENDING |", "| Medium | g2 | x | Pending |", "| LOW | g3 | x | Requires-Execution |")),
		bl("bl-unknown-priority", ln("## Gap-backlog", h4, "| med | g1 | x | pending |", "| urgent | g2 | x | pending |", "| 1 | g3 | x | pending |", pend)),
		bl("bl-qualifier", ln("## Gap-backlog", h4,
			"| high (ctx) | g1 | x | pending |", "| medium  (a (b) c) | g2 | x | pending |", "| foo (bar) | g3 | x | pending |", "| (x) | g4 | x | pending |",
			"| deferred (y) | g5 | x | parked |", "| low (a)(b) | g6 | x | pending |", "| high ( | g7 | x | pending |", pend)),
		bl("bl-closed-class", ln("## Gap-backlog", h4,
			"| deferred | G1 | x | ✅ done |", "| deferred | G2 | x | parked |", "| ~~high~~ | G3 | x | closed |", "| ~~x | G4 | x | closed |", "| ~~~ | G5 | x | closed |",
			"| — | G6 | x | closed |", "| —x | G7: note | x | covered |", "| — | G8 (later) | x | closed |", "| — | G9 | x | pending |", "| — | G10 | x | **Open** (n) |",
			"| — | a note | x | closed |", "| — | `**[G11]**` | x | closed |", "| — | Gx | x | closed |", "| — | G12·b | x | closed |", "| — | G13—b | x | closed |", "| — | G14 | x | queued |", "| — | G15 | x | blocked on hw |", pend)),
		bl("bl-closed-class-5", ln("## Gap-backlog", h5,
			"| deferred | ~~B1-G1~~ | a | x | parked |", "| deferred | B1-G2 | ~~b~~ | x | parked |", "| deferred | B1-G3 | c | x | ✅ |", "| deferred | B1-G4 | d | x | parked |",
			"| ~~low~~ | B1-G5 | e | x | **closed** |", "| — | B1-G6 | f | x | closed |", "| — | B1-G7 | f | x | closed | extra |")),
		bl("bl-closed-class-malformed", ln("## Gap-backlog", h4, "| deferred | G1 | x |", "| — | G2 | x | closed | y |", "| ~~high~~ | G3 | x |", pend)),
		bl("bl-closed-class-outside", ln("## Notes", h4, "| deferred | G1 | x | ✅ |", "| — | G2 | x | closed |", "", "## Backlog notes", h4, "| deferred | G3 | x | ✅ |", "| — | G4 | x | closed |")),
		bl("bl-closed-class-outside-header", ln("## Notes", "| Priority | Gap | Type | Status |", "|---|---|---|---|", "| deferred | G1 | x | ✅ |", "| — | G2 | x | closed |", "| ~~high~~ | G3 | x | closed |")),
		bl("bl-closed-class-bad-width", ln("## Gap-backlog", "| Priority | Gap | Type |", "|---|---|---|", "| deferred | G1 | ✅ |", pend)),
		bl("bl-oob-header", ln("## Gap-backlog", h4, pend, "", "## Other", h4, "| high | oob1 | x | pending |", "| low | oob2 | x | pending |", "", "## Next", "text")),
		bl("bl-oob-eof", ln("## Gap-backlog", h4, pend, "", "## Other", "| Priority | Gap | Type | Status |", "|---|---|---|---|", "| high | oob1 | x | pending |")),
		bl("bl-oob-5col", ln("## Other", h5, "| high | O1 | a | x | pending |", "| deferred | O2 | b | x | ✅ |")),
		bl("bl-oob-no-header", ln("## Notes", "| Severity | Gap | Type | Status |", "|---|---|---|---|", "| high | n1 | x | pending |", "| low | n2 | x | pending |", "| bogus | n3 | x | pending |")),
		bl("bl-oob-no-separator", ln("## Notes", "| high | n1 | x | pending |")),
		bl("bl-oob-bad-width", ln("## Notes", "| Priority | Gap |", "|---|---|", "| high | n1 |", "| high | n2 | x | pending |")),
		bl("bl-oob-next-heading-resets", ln("## Gap-backlog", h4, pend, "## Other", h4, "| low | o1 | x | pending |", "## Gap-backlog", h4, "| low | in | x | pending |")),
		bl("bl-nearmiss", ln("## Gap backlog", h4, "| high | g1 | x | pending |", "| bogus | g2 | x | pending |", "| deferred | g3 | x | ✅ |", "| ~~low~~ | g4 | x | closed |")),
		bl("bl-nearmiss-no-header", ln("## Backlog", "| Severity | Gap | Type | Status |", "|---|---|---|---|", "| high | g1 | x | pending |", "| bogus | g2 | x | pending |", "| bogus | g3 | x | pending |", "| deferred | g4 | x | ✅ |")),
		bl("bl-nearmiss-closed-first", ln("## Backlog", "| Severity | Gap | Type | Status |", "|---|---|---|---|", "| deferred | g1 | x | ✅ |", "| ~~high~~ | g2 | x | closed |", "| high | g3 | x | pending |")),
		bl("bl-nearmiss-bogus-first", ln("## Backlog", "| Severity | Gap | Type | Status |", "|---|---|---|---|", "| bogus | g1 | x | pending |", "| bogus | g2 | x | pending |")),
		bl("bl-nearmiss-no-separator", ln("## Backlog", "| high | g1 | x | pending |", "| bogus | g2 | x | pending |", "| deferred | g3 | x | ✅ |", "| ~~low~~ | g4 | x | closed |")),
		bl("bl-no-separator-unknown", ln("## Gap-backlog", "| med | g1 | x | pending |", "| high (c) | g2 | x | pending |", "| foo (c) | g3 | x | pending |", "| high | g4 | x |", "| low | g5 | x | covered | y |", "| deferred | g6 | x |", "| — | G7 | x | closed | y |", "| ~~low~~ | g8 | x |")),
		bl("bl-p-header-in-backlog", ln("## Gap-backlog", "| P | Gap | Type | Status |", "|---|---|---|---|", pend, "", "| Pr. | Gap | Type | Status |", "|---|---|---|---|", "| low | g2 | x | pending |")),
		bl("bl-header-row-repeated-in-data", ln("## Gap-backlog", h4, pend, "| P | Gap | Type | Status |", "| Priority | Gap | Type | Status |", "| priority | Gap | Type | Status |", "|  | Gap | Type | Status |")),
		bl("bl-closed-no-separator", ln("## Gap-backlog", "| deferred | G1 | x | ✅ |", "| ~~high~~ | G2 | x | closed |", "| ~~~~ | G3 | x | closed |", "| — | G4 | x | closed |", "| high | g5 | x | pending |")),
		bl("bl-nearmiss-numeric", ln("## Gap-backlog heading", h4, "| 1 | g1 | x | pending |", "| 2 | g2 | x | pending |", "| bold | g3 | x | pending |")),
		bl("bl-nearmiss-then-heading", ln("## Backlog one", h4, "| high | a | x | pending |", "## Backlog two", h4, "| high | b | x | pending |", "## Plain", h4, "| high | c | x | pending |", "## Plain two", h4, "| high | d | x | pending |")),
		bl("bl-nearmiss-oob-flush", ln("## Notes", h4, "| high | n1 | x | pending |", "## Gap backlog (x)", h4, "| high | n2 | x | pending |")),
		bl("bl-heading-qualifiers", ln("## Gap-backlog (a)", h4, "| high | a | x | pending |", "## Gap-backlog ()", h4, "| high | b | x | pending |", "## Gap-backlog (a))", h4, "| high | c | x | pending |", "## Gap-backlog (x) y", h4, "| high | d | x | pending |", "## Gap-backlog(z)", h4, "| high | e | x | pending |")),
		bl("bl-u2011-heading", ln("## Gap‑backlog (prioritized)", h4, "| high | a | x | pending |")),
		bl("bl-two-sections", ln("## Gap-backlog (a)", h4, "| high | a | x | pending |", "", "## Gap-backlog (b)", h4, "| low | b | x | pending |")),
		bl("bl-width-3", ln("## Gap-backlog", "| Priority | Gap | Status |", "|---|---|---|", "| high | g1 | pending |", "| low | g2 | pending |")),
		bl("bl-width-6", ln("## Gap-backlog", "| Priority | Gap | A | B | C | D |", "|---|---|---|---|---|---|", "| high | g1 | a | b | c | d |", "| deferred | g2 | a | b | c | d |")),
		bl("bl-malformed-row", ln("## Gap-backlog", h4, "| high | g1 | x |", "| high | g2 | x | pending | extra |", "| low | g3 | x | covered | extra |", "| low | g4 | x | Covered (a|b) |", pend)),
		bl("bl-malformed-row-5", ln("## Gap-backlog", h5, "| high | B1 | g1 | x |", "| high | B2 | g2 | x | covered | y |", "| high | B3 | g3 | x | pending | y |")),
		bl("bl-no-separator", ln("## Gap-backlog", "| high | g1 | x | pending |", "| high | g2 | x | x | pending |", "| low | g3 | x | pending |")),
		bl("bl-separator-first-cell-colon", ln("## Gap-backlog", "| Priority | Gap | Type | Status |", "|:--|---|---|---|", "|---|---|---|---|", pend)),
		bl("bl-priority-header-bold", ln("## Notes", "| **Priority** | Gap | Type | Status |", "|---|---|---|---|", "| high | g1 | x | pending |")),
		bl("bl-priority-header-forms", ln("## A", "| Pr. | Gap | Type | Status |", "|---|---|---|---|", "| high | a | x | pending |", "## B", "| P | Gap | Type | Status |", "|---|---|---|---|", "| high | b | x | pending |", "## C", "| Prioridad | Gap | Type | Status |", "|---|---|---|---|", "| high | c | x | pending |", "## D", "| Pri | Gap | Type | Status |", "|---|---|---|---|", "| high | d | x | pending |")),
		bl("bl-escaped-pipe", ln("## Gap-backlog", h4, "| high | a\\|b | x | pending\\|more |", "| low | c\\\\| d | x | pending |", "| low | e | x\\| | pending |", "| deferred | f\\|g | x | parked\\|h |")),
		bl("bl-crlf", "## Gap-backlog\r\n"+h4+"\r\n| high | g1 | x | pending |\r\n| low | g2 | x | done |\r\n| deferred | g3 | x | parked |\r\n"),
		bl("bl-crlf-heading", "## Gap-backlog\r\n"+h4+"\n| high | g1 | x | pending |\n"),
		bl("bl-no-trailing-newline", "## Gap-backlog\n"+h4+"\n| high | g1 | x | pending |"),
		bl("bl-indented-rows", ln("## Gap-backlog", h4, "  | high | g1 | x | pending |", "\t| low | g2 | x | pending |", "see a | b", "- item | with pipe", "  prose | text | here | now")),
		bl("bl-prose-pipe-rows", ln("## Gap-backlog", h4, "high | g1 | x | pending", "| high | g2 | x | pending", "high | g3 | x | pending |")),
		bl("bl-list-item-guard", ln("## Gap-backlog", h4, "| - item | a | b | c |", "| -- | a | b | c |", pend)),
		bl("bl-empty-cells", ln("## Gap-backlog", h4, "| high |  | x | pending |", "| high | g2 | x |  |", "|  | g3 | x | pending |", "| high | g4 |  | pending |", "||", "|", "| |", "| high |  | x |  |", "| deferred |  | x |  |")),
		bl("bl-tabs-in-cells", ln("## Gap-backlog", h4, "|\thigh\t|\tg1\t|\tx\t|\tpending\t|", "| high | g\t2 | x | pending\tnote |")),
		bl("bl-status-forms", ln("## Gap-backlog", h4, "| high | g1 | x | **pending** |", "| high | g2 | x | **pending |", "| high | g3 | x | pending** |", "| high | g4 | x | ** |", "| high | g5 | x | **a** b **c** |", "| high | g6 | x | **PENDING** (UNCOVERED by B7) |")),
		bl("bl-non-ascii", ln("## Gap-backlog", h4, "| HIGH | Ñandú | x | PENDIENTE |", "| ÉLEVÉ | g2 | x | pending |", "| high | g3 — x | x | pending ✅ |", "| — | G1· | x | closed |", "| — | Ø1 | x | closed |")),
		bl("bl-non-utf8", "## Gap-backlog\n"+h4+"\n| high | g\xff1 | x | pending |\n| \xe2\x80 | g2 | x | pending |\n| — | G1\xe2\x80x | x | closed |\n"),
		bl("bl-retyped", ln("## Gap-backlog", h4, pend, "| medium | rt-first | web | re-typed [Block 141] — blocked-pending-native-gate |", "| low | rt-mid | web | **retyped** (moved) |", "| low | rt-last | web | Re-Typed |", "| low | ~~old gap~~ | web | re-typed |")),
		bl("bl-retyped-edges", ln("## Gap-backlog", h4, "| high | rt1 | web | re-typed |", "| high | pending-one | web | pending |", "| high | rt2 | web | retyped-x |", "| high | none | web | re-type |")),
		bl("bl-status-tokens", ln("## Gap-backlog", h4,
			"| high | t1 | x | pending |", "| high | t2 | x | pending (uncovered by B7) |", "| high | t3 | x | not pending |", "| high | t4 | x | blocked (pending review) |", "| high | t5 | x | blocked |",
			"| high | t6 | x | blocked: needs tool |", "| high | t7 | x | blocked, see below |", "| high | t8 | x | blocked-on-tool: x |", "| high | t9 | x | requires-execution (hw) |",
			"| high | t10 | x | ✅ covered |", "| high | t11 | x | ~~x~~ |", "| high | t12 | x | closed |", "| high | t13 | x | [closed] |", "| high | t14 | x | covered |", "| high | t15 | x | [covered] |",
			"| high | t16 | x | done |", "| high | t17 | x | [done] |", "| high | t18 | x | cubierto |", "| high | t19 | x | [cubierto] |", "| high | t20 | x | wip |", "| high | t21 | x | in progress |",
			"| high | t22 | x | blocked-onx |", "| high | t23 | x | blockedx |")),
		bl("bl-requires-execution", ln("## Gap-backlog", h4, "| high | r1 | x | requires-execution |", "| high | r2 | x | requires-execution-hw |", "| high | r3 | x | requires-executionx |", "| high | r4 | x | requires-execution (note) |",
			"| high | r5 | x | **requires-execution** |", "| high | r6 | x | pending (requires-execution) |", "| high | ~~r7~~ | x | requires-execution |", "| high | r8 | x | requires-execution ✅ |", "| high | r9 | x | requires-execution ~~gone~~ |",
			"| high | r10 | x | requires-execution9 |", "| high | r11 | x | requires-execution. |", "| high | r12 | x | Requires-Execution |", "| high | r13 | x | requires-execution_x |", "| high | r14 | x | requires-execution:x |")),
		bl("bl-struck-gap", ln("## Gap-backlog", h4, "| high | ~~G1~~ | x | pending |", "| high | G2 ~~x~~ | x | pending |", "| high | G3 | x | requires-execution |")),
		bl("bl-blocked-section", ln("## Gap-backlog", h4, pend, "| high | gap-b | x | pending |", "| medium | blk-first | web | blocked (requires-hardware) |", "| low | blk-mid | web | blocked-on-tool: needs a decompiler |", "", "## Blocked gaps", "- gap-b — needs: a board", "- blk-first — needs: hw")),
		bl("bl-inplace-suite", ln("## Gap-backlog (prioritized)", "", "| Priority | Gap | Artifact type / source | Status |", "|---|---|---|---|", pend, done,
			"| medium | blk-first | web | blocked (requires-hardware) |", "| low | blk-mid | web | blocked-on-tool: needs a decompiler |", "| low | blk-last | web | blocked |",
			"| low | ~~blk-struck~~ | web | blocked (requires-x) |", "| low | blk-closed | web | blocked ✅ closed |", "| low | colon | web | blocked: needs tool |", "| low | comma | web | blocked, see below |", "", "## Stop control", "")),
		bl("bl-inplace-dual-id", ln("## Gap-backlog (prioritized)", "", "| Priority | Gap | Artifact type / source | Status |", "|---|---|---|---|", pend, done,
			"| low | AB. Builders de config del equipo (TBL_X/Y) — offsets de campo | binario X.exe | blocked-on-tool: necesita decompilar X.exe · tried: y |",
			"| low | Builders de config — x | web | blocked (requires-tool) |", "", "## Blocked gaps", "", "**AB. Offsets de campo de las tablas de config** (TBL_X/Y) — needs: a decompiler", "Builders de otra cosa — needs: tool", "")),
		bl("bl-inplace-no-needs", ln("## Gap-backlog", h4, pend, "| low | AB. Builders — x | binario X.exe | blocked-on-tool: y |", "", "## Blocked gaps", "**AB. Offsets de campo** (X) — no clause here", "")),
		bl("bl-inplace-id-case", ln("## Gap-backlog", h4, pend, "| low | ab: Builders — x | web | blocked-on-tool: y |", "", "## Non-investigable gaps", "- **AB. Offsets** (X) — needs: a decompiler", "")),
		bl("bl-known-gaps-uncounted", ln("## Gap-backlog", h4, pend, done, "| high | a | b | c | d | e |", "", "## Gap backlog", "| Priority | Gap | Type | Status |", "|---|---|---|---|", "| 1 | x | y | z |", "| deferred | d | y | ✅ |")),
		bl("bl-invalid-priority-counts", ln("## Gap-backlog", h4, pend, "| med | a | x | pending |", "| ~~high~~ | b | x | closed |")),
	}
	return scs
}

// deferredScenarios are the cases of research-sdd-status-deferred-populations.test.sh.
func deferredScenarios() []s2Scenario {
	body := map[string]string{
		"single4":    h4 + "\n| deferred | B1-G1 a | x | parked |",
		"single5":    h5 + "\n| deferred | B1-G1 | a | x | parked |",
		"first5":     h5 + "\n| deferred | B1-G1 | a | x | parked |\n| high | B1-G2 | b | x | pending |\n| high | B1-G3 | c | x | pending |",
		"mid5":       h5 + "\n| high | B1-G1 | a | x | pending |\n| deferred | B1-G2 | b | x | parked |\n| high | B1-G3 | c | x | pending |",
		"last5":      h5 + "\n| high | B1-G1 | a | x | pending |\n| high | B1-G2 | b | x | pending |\n| deferred | B1-G3 | c | x | parked |",
		"first4":     h4 + "\n| deferred | B1-G1 a | x | parked |\n| high | B1-G2 b | x | pending |\n| high | B1-G3 c | x | pending |",
		"mid4":       h4 + "\n| high | B1-G1 a | x | pending |\n| deferred | B1-G2 b | x | parked |\n| high | B1-G3 c | x | pending |",
		"last4":      h4 + "\n| high | B1-G1 a | x | pending |\n| high | B1-G2 b | x | pending |\n| deferred | B1-G3 c | x | parked |",
		"closed5":    h5 + "\n| deferred | ~~B1-G1~~ | a | x | parked |\n| deferred | B1-G2 | b | x | ~~dropped~~ |\n| deferred | B1-G3 | c | x | ✅ done |\n| deferred | B1-G4 | d | x | parked |",
		"mixed":      h4 + "\n| deferred | B1-G1 a | x | parked |\n| deferred | B1-G2 b | x | ✅ done |\n| deferred | B1-G3 c | x | parked |\n\n" + h5 + "\n| deferred | B1-G4 | d | x | parked |\n| deferred | B1-G5 | e | x | ✅ done |\n| deferred | B1-G6 | f | x | parked |",
		"esc5":       h5 + "\n| deferred | B1-G1 | a\\|b | x | parked\\|more |",
		"barepipe":   h4 + "\n| deferred | B1-G1 a | x | ✅ done | y |\n| deferred | B1-G2 b | x | parked |",
		"wide6":      h5 + "\n| deferred | B1-G1 | a | x | parked | extra |\n| deferred | B1-G2 | b | x | parked |",
		"outside":    h4 + "\n| deferred | B1-G1 a | x | parked |\n\n## Notes\n| Severity | Gap | Type | Status |\n|---|---|---|---|\n| deferred | B1-G2 n | x | parked |",
		"outsidehdr": h4 + "\n| deferred | B1-G1 a | x | parked |\n\n## Other backlog\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| deferred | B1-G2 n | x | parked |",
		"scope5":     h5s + "\n| deferred | B1-G1 a | s | w | parked |\n| deferred | ~~B1-G2 b~~ | s | w | parked |\n| deferred | B1-G3 c | ~~s~~ | w | parked |",
		"struck5":    h5 + "\n| deferred | B1-G1 | a | x | parked |\n| deferred | B1-G2 | ~~b~~ | x | parked |",
	}
	var out []s2Scenario
	for _, name := range []string{"single4", "single5", "first5", "mid5", "last5", "first4", "mid4", "last4", "closed5", "mixed", "esc5", "barepipe", "wide6", "outside", "outsidehdr", "scope5", "struck5"} {
		state := "# Deferred populations\nnext_session_queue: B1-G1\n\n## Gap-backlog (prioritized)\n" + body[name] + "\n\n## Iteration history\n| It | Focus | Block | New gaps |\n|---|---|---|---|\n| 1 | f | B1 | 1 |\n"
		out = append(out, bl("def-"+name, state))
	}
	out = append(out,
		bl("def-bold-status", ln("## Gap-backlog", h4, "| deferred | G1 | x | **parked** |", "| **deferred** | G2 | x | parked |", "| Deferred | G3 | x | **✅** |", "| deferred | G4 | x |  |")),
		bl("def-width-in-bad-table", ln("## Gap-backlog", "| Priority | Gap | Type |", "|---|---|---|", "| deferred | G1 | parked |")),
		bl("def-heading-reset", ln("## Gap-backlog", "| deferred | G1 | x | parked |", "## Other", "| deferred | G2 | x | parked |", "## Gap-backlog (b)", h4, "| deferred | G3 | x | parked |")),
		bl("def-bold-priority-header", ln("## Notes", "| **Priority** | Gap | Type | Status |", "|---|---|---|---|", "| deferred | G1 | x | parked |", "", "prose", "| deferred | G2 | x | parked |")),
		bl("def-header-then-prose", ln("## Notes", "| Priority | Gap | Type | Status |", "no pipes here", "|---|---|---|---|", "| deferred | G1 | x | parked |")),
		bl("def-crlf", "## Gap-backlog\r\n"+h4+"\r\n| deferred | G1 | x | parked |\r\n"),
		bl("def-no-trailing-newline", "## Gap-backlog\n"+h4+"\n| deferred | G1 | x | parked |"),
	)
	return out
}

// envState is a state file with a full envelope and the sections the counters read.
func envScenarios() []s2Scenario {
	env := func(name, state string, ops ...op) s2Scenario { return s2Scenario{name: name, state: state, ops: ops} }
	getAll := func(keys ...string) []op {
		var ops []op
		for _, k := range keys {
			ops = append(ops, o("env_get", k), o("env_raw", k))
		}
		return ops
	}
	keys := []string{"covered_blocks", "known_gaps", "deferred_open", "nokey", "block_scope", "next"}
	return []s2Scenario{
		env("env-basic", ln("# S", "<!-- research-state.v1 -->", "schema: research-state.v1", "covered_blocks: 3", "known_gaps: 12", "deferred_open: 0", "block_scope: shared-global", "<!-- /research-state.v1 -->", "known_gaps: 99"), getAll(keys...)...),
		env("env-crlf", "<!-- research-state.v1 -->\r\ncovered_blocks: 3\r\nknown_gaps:\r\n<!-- /research-state.v1 -->\r\n", getAll(keys...)...),
		env("env-indent", ln("<!-- research-state.v1 -->", "  covered_blocks: 3", "\tknown_gaps:   12   x  ", "<!-- /research-state.v1 -->"), getAll(keys...)...),
		env("env-multi-field", ln("<!-- research-state.v1 -->", "covered_blocks: 3 4 5", "known_gaps:5", "deferred_open :0", "block_scope: a b", "<!-- /research-state.v1 -->"), getAll(keys...)...),
		env("env-outside", ln("covered_blocks: 1", "<!-- research-state.v1 -->", "<!-- /research-state.v1 -->", "known_gaps: 2"), getAll(keys...)...),
		env("env-no-close", ln("<!-- research-state.v1 -->", "covered_blocks: 7", "known_gaps: 8", "## Later", "deferred_open: 9"), getAll(keys...)...),
		env("env-two-blocks-first-wins", ln("<!-- research-state.v1 -->", "covered_blocks: 1", "<!-- /research-state.v1 -->", "<!-- research-state.v1 -->", "covered_blocks: 2", "known_gaps: 4", "<!-- /research-state.v1 -->"), getAll(keys...)...),
		env("env-marker-dot-wildcard", ln("<!-- research-stateXv1 -->", "covered_blocks: 5", "<!-- /research-state-v1 -->", "known_gaps: 6"), getAll(keys...)...),
		env("env-marker-indented", ln("  <!-- research-state.v1 --> trailing", "covered_blocks: 5", "x <!-- /research-state.v1 --> y", "known_gaps: 6"), getAll(keys...)...),
		env("env-key-like-prefix", ln("<!-- research-state.v1 -->", "covered_blocks_extra: 1", "known_gaps_x: 2", "xknown_gaps: 3", "known_gaps: 4", "<!-- /research-state.v1 -->"), getAll(keys...)...),
		env("env-blank-lines", ln("<!-- research-state.v1 -->", "", "   ", "covered_blocks: 3", "", "<!-- /research-state.v1 -->"), getAll(keys...)...),
		env("env-none", ln("# S", "no envelope"), getAll(keys...)...),
		env("env-empty", "", getAll(keys...)...),
		env("env-raw-trailing-ws", ln("<!-- research-state.v1 -->", "block_scope:   a  b \t ", "next:", "next2: x", "<!-- /research-state.v1 -->"), o("env_raw", "block_scope"), o("env_raw", "next"), o("env_raw", "next2"), o("env_get", "next"), o("env_get", "block_scope")),
		env("env-pick", ln("<!-- research-state.v1 -->", "known_gaps: 5", "deferred_open: x", "<!-- /research-state.v1 -->"),
			o("pick", "7", "5"), o("pick", "", "5"), o("pick", "x", "5"), o("pick", "", ""), o("pick", "x", "y"), o("pick", "7x", "5"), o("pick", "007", ""), o("pick", "-1", "4"), o("pick", " 3", "4"), o("pick", "", "4 "), o("pick", "0", "9")),
	}
}

func sectionScenarios() []s2Scenario {
	reqs := func(name, stop string) s2Scenario {
		return s2Scenario{name: name, state: "# S\n## Stop control\n" + stop, ops: []op{o("req_prose"), o("stopctl"), o("section", "## Stop control")}}
	}
	cov := func(name, body string) s2Scenario {
		return s2Scenario{name: name, state: "# S\n## Coverage\n" + body, ops: []op{o("cov_ratio"), o("section", "## Coverage")}}
	}
	return []s2Scenario{
		reqs("req-logosoft", ln("", "- **Open gaps — requires-execution (NO read-only; …, METHODOLOGY §8)**: **0 — AGOTADO.**", "- other", "", "## Next", "requires-execution: 5")),
		reqs("req-plain", ln("- Open gaps — requires-execution: 4", "- more: 9")),
		reqs("req-case", ln("- REQUIRES-EXECUTION left = 12 (of 30)")),
		reqs("req-no-number", ln("- requires-execution: none", "- other 5")),
		reqs("req-number-next-line-only", ln("- requires-execution", "- 8 other")),
		reqs("req-first-line-without-number", ln("- requires-execution: none", "- requires-execution: 3")),
		reqs("req-nested-parens", ln("- requires-execution (a (b) 5) n 6")),
		reqs("req-unclosed-paren", ln("- requires-execution (open 5 and 6")),
		reqs("req-two-groups", ln("- (x) requires-execution (y) 7 (z)")),
		reqs("req-leading-zeros", ln("- requires-execution 007")),
		reqs("req-token-twice", ln("- requires-execution requires-execution 4")),
		reqs("req-token-at-line-start", ln("requires-execution 9", "- x")),
		reqs("req-digit-right-after-token", ln("- requires-execution7 left")),
		reqs("req-absent", ln("- nothing here 3")),
		{name: "req-no-section", state: "# S\n", ops: []op{o("req_prose"), o("stopctl")}},
		reqs("req-heading-prefix", ln("- requires-execution 1", "## Stop control (more)", "- requires-execution 2")),
		{name: "section-multi", state: ln("## Stop control", "a", "## Other", "b", "## Stop control v2", "c", "### sub", "d"), ops: []op{o("section", "## Stop control"), o("stopctl"), o("section", "## Other"), o("section", "## Nope")}},
		cov("cov-basic", ln("- **Coverage metric**: 3 / 5 closed", "- other 1/2")),
		cov("cov-plain-equals", ln("Coverage metric = 7/9")),
		cov("cov-qualified", ln("- **Coverage metric (this focus)**: 2 / 4 gaps")),
		cov("cov-bold-after", ln("* **Coverage metric** (x)**: 5/6")),
		cov("cov-no-ratio-label", ln("- Coverage metric:", "- see Coverage metric 3/4 in outline")),
		cov("cov-loose-only", ln("- the coverage metric is 3/4 now")),
		cov("cov-loose-long", ln("- the coverage metric is "+strings.Repeat("x", 120)+" 3/4")),
		cov("cov-loose-no-ratio", ln("- the coverage metric is unknown")),
		cov("cov-label-case", ln("- COVERAGE METRIC: 10/20")),
		cov("cov-tab-in-ratio", ln("- Coverage metric: 3\t/\t5")),
		cov("cov-first-label-wins", ln("- Coverage metric: n/a", "- Coverage metric: 4/8", "- Coverage metric: 1/2")),
		cov("cov-indent-and-plus", ln("   + Coverage metric: 6 / 7")),
		cov("cov-not-anchored", ln("- Gap coverage metric: 3/4")),
		cov("cov-empty-section", ""),
		{name: "cov-no-section", state: "# S\n", ops: []op{o("cov_ratio")}},
		{name: "cov-warn-basename", state: "## Coverage\n- coverage metric 3/4\n", ops: []op{o("cov_ratio")}},
	}
}

func attributedScenarios() []s2Scenario {
	at := func(name, state string) s2Scenario {
		return s2Scenario{name: name, state: state, ops: []op{o("count_attributed_sg")}}
	}
	hist := func(rows ...string) string {
		return "## Iteration history\n" + strings.Join(append([]string{"| It | Focus | Block | New gaps |", "|---|---|---|---|"}, rows...), "\n") + "\n"
	}
	return []s2Scenario{
		at("sg-covered-blocks", ln("## Covered blocks", "B1 and B2, also B2 again", "B10", "## Other", "B99")),
		at("sg-covered-blocks-boundaries", ln("## Covered blocks", "AB1 B2x B_3 _B4 B5_ (B6) B7. -B8- B9-1 B10/B11 xB12 B13B14 B")),
		at("sg-covered-blocks-multiline", ln("## Covered blocks", "B1", "", "B1", "B2", "b3")),
		at("sg-covered-blocks-empty-falls-back", ln("## Covered blocks", "none yet", hist("| 1 | f | B4 | 2 |", "| 2 | f | B5 | 1 |"))),
		at("sg-history-block-column", hist("| 1 | f | B1 | 2 |", "| 2 | f | B2, B3 | 1 |", "| 3 | f | B1 | 1 |")),
		at("sg-history-no-leading-pipe", ln("## Iteration history", "It | Focus | Block | New", "---|---|---|---", "1 | f | B1 | 2 |", "2 | f | B2 | 1")),
		at("sg-history-header-no-block", hist("| 1 | f | B1 | 2 |")+"\n"+ln("| It | Focus | Notes |", "|---|---|---|", "| 1 | f | B3 |")),
		at("sg-history-mixed-pipe-styles", ln("## Iteration history", "| It | Focus | Block |", "|---|---|---|", "| 1 | f | B1 |", "2 | g | B2 |", "3 | h | B3", " | 4 | i | B4 |")),
		at("sg-history-short-row", ln("## Iteration history", "| It | Focus | Block |", "|---|---|---|", "| 1 | f |", "| 2 | g | B2 |")),
		at("sg-history-escaped-pipe", ln("## Iteration history", "| It | Focus | Block |", "|---|---|---|", "| 1 | a\\|b | B1 |", "| 2 | g | B2\\|B3 |")),
		at("sg-history-crlf", "## Iteration history\r\n| It | Focus | Block |\r\n|---|---|---|\r\n| 1 | f | B1 |\r\n| 2 | g | B2\r\n"),
		at("sg-history-duplicate-block-header", ln("## Iteration history", "| Block | Focus | Block |", "|---|---|---|", "| B1 | f | B2 |")),
		at("sg-history-header-case", ln("## Iteration history", "| It | BLOCK |", "|---|---|", "| 1 | B1 |", "| 2 | B1 |")),
		at("sg-history-padded-header", ln("## Iteration history", "| It |  Block  |", "|---|---|", "| 1 | B7 |")),
		at("sg-history-crlf-no-trailing-pipe", "## Iteration history\r\n| It | Focus | Block\r\n|---|---|---\r\n| 1 | f | B1\r\n| 2 | g | B2\r\n"),
		at("sg-none", ln("## Other", "B1")),
		at("sg-empty", ""),
		at("sg-history-no-ids", hist("| 1 | f | none | 2 |")),
	}
}

func focusScenarios() []s2Scenario {
	const sb = "RESEARCH-STATE-alpha.md"
	fs := func(name, focuses string, sbase ...string) s2Scenario {
		if len(sbase) == 0 {
			sbase = []string{sb}
		}
		var ops []op
		for _, b := range sbase {
			ops = append(ops, o("_read_focuses_tok_uncached", "{ROOT}/corpus/FOCUSES.md", b), o("__into_twice", "{ROOT}/corpus/FOCUSES.md", b))
		}
		return s2Scenario{name: name, state: "# S\n", extra: map[string]string{"corpus/FOCUSES.md": focuses}, ops: ops}
	}
	hdr := "| Focus | Status | Research-State |\n|---|---|---|\n"
	return []s2Scenario{
		fs("foc-basic", hdr+"| alpha | active | RESEARCH-STATE-alpha.md |\n| beta | paused | RESEARCH-STATE-beta.md |\n", sb, "RESEARCH-STATE-beta.md", "RESEARCH-STATE-gamma.md"),
		fs("foc-every-token", "| Focus | Status |\n|---|---|\n| a1 | active |\n| a2 | paused |\n| a3 | stopped |\n| a4 | planned |\n| a5 | bootstrapping |\n| a6 | reopened |\n| a7 | document |\n| a8 | closed |\n| a9 | Active |\n",
			"RESEARCH-STATE-a1.md", "RESEARCH-STATE-a2.md", "RESEARCH-STATE-a3.md", "RESEARCH-STATE-a4.md", "RESEARCH-STATE-a5.md", "RESEARCH-STATE-a6.md", "RESEARCH-STATE-a7.md", "RESEARCH-STATE-a8.md", "RESEARCH-STATE-a9.md"),
		fs("foc-decorated-status", "| Focus | Status |\n|---|---|\n| a1 | **active** (note) |\n| a2 | `paused` |\n| a3 | [stopped](x.md) later |\n| a4 | **planned |\n| a5 | [`active`](u) |\n| a6 | [a](b) c |\n| a7 | **pau**sed |\n| a8 |  |\n| a9 | [x]() |\n",
			"RESEARCH-STATE-a1.md", "RESEARCH-STATE-a2.md", "RESEARCH-STATE-a3.md", "RESEARCH-STATE-a4.md", "RESEARCH-STATE-a5.md", "RESEARCH-STATE-a6.md", "RESEARCH-STATE-a7.md", "RESEARCH-STATE-a8.md", "RESEARCH-STATE-a9.md"),
		fs("foc-decorated-identity", "| Focus | Status |\n|---|---|\n| **alpha** | active |\n| `beta` | paused |\n| [gamma](g.md) | stopped |\n| RESEARCH-STATE-delta.md | planned |\n| a | b | c |\n",
			"RESEARCH-STATE-alpha.md", "RESEARCH-STATE-beta.md", "RESEARCH-STATE-gamma.md", "RESEARCH-STATE-delta.md", "RESEARCH-STATE-a.md"),
		fs("foc-state-file-column", "| Name | State file | Estado |\n|---|---|---|\n| x | RESEARCH-STATE-alpha.md | Active |\n| y | `beta` | paused |\n| x |\n", sb, "RESEARCH-STATE-beta.md", "RESEARCH-STATE-x.md"),
		fs("foc-no-status-column", "| Focus | Notes |\n|---|---|\n| alpha | active |\n| beta |\n", sb, "RESEARCH-STATE-beta.md"),
		fs("foc-status-col-beyond-row", "| Focus | A | Status |\n|---|---|---|\n| alpha |\n", sb),
		fs("foc-state-file-only", "| Name | State file |\n|---|---|\n| x | RESEARCH-STATE-alpha.md |\n", sb),
		fs("foc-fallback-phantom-cell", "| Focus |\t\n|---|\n| alpha |\t\n", sb),
		fs("foc-fallback-phantom-cell-space", "| Focus | \n|---|\n| alpha | \n", sb),
		fs("foc-no-focus-column", "| Name | Status |\n|---|---|\n| alpha | active |\n", sb),
		fs("foc-status-fallback-next-column", "| Focus | Whatever |\n|---|---|\n| alpha | paused |\n", sb),
		fs("foc-duplicate-headers-last-wins", "| Focus | Status | Focus | Estado |\n|---|---|---|---|\n| x | active | alpha | stopped |\n", sb, "RESEARCH-STATE-x.md"),
		fs("foc-header-case", "| FOCUS | STATUS | STATE FILE |\n|---|---|---|\n| alpha | active | - |\n", sb),
		fs("foc-no-row", hdr+"| beta | paused | RESEARCH-STATE-beta.md |\n", sb),
		fs("foc-only-header", hdr, sb),
		fs("foc-no-table", "no table here\n", sb),
		fs("foc-empty-file", "", sb),
		fs("foc-separator-variants", "| Focus | Status |\n|:--|--:|\n| alpha | active |\n|:-:|:-:|\n| beta | paused |\n", sb, "RESEARCH-STATE-beta.md"),
		fs("foc-separator-only-first", "|---|---|\n| Focus | Status |\n| alpha | active |\n", sb),
		fs("foc-zero-cell-rows", "||\n|\n| Focus | Status |\n|---|---|\n||\n| alpha | active |\n", sb),
		fs("foc-first-match-wins", "| Focus | Status |\n|---|---|\n| alpha | paused |\n| alpha | active |\n", sb),
		fs("foc-nonconforming-then-valid", "| Focus | Status |\n|---|---|\n| alpha | halted |\n| alpha | active |\n", sb),
		fs("foc-indented-row-quirk", "| Focus | Status |\n|---|---|\n  | alpha | active |\n", sb),
		fs("foc-indented-header-quirk", "  | Focus | Status |\n|---|---|\n| alpha | active |\n", sb),
		fs("foc-tab-indent-quirk", "| Focus | Status |\n|---|---|\n\t| alpha | active |\n", sb),
		fs("foc-trailing-blank-quirk", "| Focus | Status |  \n|---|---|\n| alpha | active |   \n| beta | paused |\t\n", sb, "RESEARCH-STATE-beta.md"),
		fs("foc-indent-and-trailing-blank", "| Focus | Status |\n|---|---|\n  | alpha | active |  \n", sb),
		fs("foc-no-outer-pipes", "Focus | Status\n---|---\nalpha | active\n", sb),
		fs("foc-no-leading-pipe", "Focus | Status |\n---|---|\nalpha | active |\n", sb),
		fs("foc-no-trailing-pipe", "| Focus | Status\n|---|---\n| alpha | active\n", sb),
		fs("foc-escaped-pipe", "| Focus | Status |\n|---|---|\n| al\\|pha | active |\n| alpha | pau\\|sed |\n| gamma | active\\| |\n", sb, "RESEARCH-STATE-al|pha.md", "RESEARCH-STATE-gamma.md"),
		fs("foc-crlf", "| Focus | Status |\r\n|---|---|\r\n| alpha | active |\r\n| beta | paused\r\n", sb, "RESEARCH-STATE-beta.md"),
		fs("foc-prose-pipe-line-is-header", "see a | b\n| Focus | Status |\n|---|---|\n| alpha | active |\n", sb),
		fs("foc-slug-forms", "| Focus | Status |\n|---|---|\n| alpha | active |\n| beta.md | paused |\n", "RESEARCH-STATE-alpha.md", "alpha", "RESEARCH-STATE-beta.md.md", "RESEARCH-STATE-.md", "other.md"),
		{name: "foc-missing-file", state: "# S\n", ops: []op{o("_read_focuses_tok_uncached", "{ROOT}/corpus/FOCUSES.md", sb), o("__into_twice", "{ROOT}/corpus/FOCUSES.md", sb)}},
		{name: "foc-file-is-directory", state: "# S\n", extra: map[string]string{"corpus/FOCUSES.md/x": ""}, ops: []op{o("_read_focuses_tok_uncached", "{ROOT}/corpus/FOCUSES.md", sb)}},
	}
}

func miscScenarios() []s2Scenario {
	return []s2Scenario{
		{name: "warn-inplace-blocked", state: "# S\n", ops: []op{o("warn_inplace_blocked", "RESEARCH-STATE.md", "3"), o("warn_inplace_blocked", "f.md", "0"), o("warn_inplace_blocked", "f.md"), o("warn_inplace_blocked", "f.md", "-2"), o("warn_inplace_blocked", "f.md", "1")}},
		{name: "unreadable-state", state: "## Gap-backlog\n" + h4 + "\n| high | g1 | x | pending |\n", unreadable: true, ops: []op{o("count_investigable"), o("count_retyped_in_table"), o("count_requires_execution"), o("count_uncounted_rows"), o("__inplace")}},
	}
}

// s2Scenarios is every scenario of the S2 differential and replay tests.
func s2Scenarios() []s2Scenario {
	var all []s2Scenario
	for _, g := range [][]s2Scenario{backlogScenarios(), deferredScenarios(), envScenarios(), sectionScenarios(), attributedScenarios(), focusScenarios(), miscScenarios()} {
		all = append(all, g...)
	}
	return all
}
