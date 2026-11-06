package show

// Scenarios added by the S8c tooth audit: each pins a fault the retired bash teeth injected into the script body
// (see odd/tasks/status-show-go.md). The differential runs them against the frozen script, the replay against the port.

// s8cBacklogScenarios are the backlog_rows / count_uncounted_rows fixtures of the retired B50-* teeth.
func s8cBacklogScenarios() []s2Scenario {
	const (
		proseClosed = "— note: rows use the a | b convention"       // a closed-class lead cell, but not a table row
		proseTier   = "low | prose with | several | pipes | inside" // a tier lead cell with extra pipes, not a table row
	)
	pend := "| high | g1 | web | pending |"
	done := "| low | g2 | web | ✅ B1 |"
	return []s2Scenario{
		// B50-PROSE-CLOSED: prose that reads as a closed-class cell is not an uncounted ROW.
		bl("bl-prose-closed-class-line-is-not-an-uncounted-row", ln("## Gap-backlog", h4, "| — | e1 | web | ✅ B1 |", "| — | e2 | web | ✅ B2 |", pend, "", proseClosed, "")),
		// B50-PROSE-TIER: prose after the rows whose lead cell is a tier is not an uncounted row either.
		bl("bl-prose-tier-line-is-not-an-uncounted-row", ln("## Gap-backlog", h4, pend, done, "", proseTier, "")),
		// B50-PROSE-FIRST: the same prose line ahead of the first row.
		bl("bl-prose-tier-line-before-the-first-row", ln("## Gap-backlog", h4, "", proseTier, pend, done, "")),
		// B50-INDENTED-ROW: an indented row of the wrong width is still a row, so it IS uncounted.
		bl("bl-indented-malformed-row-is-uncounted", ln("## Gap-backlog", h4, pend, done, "   | low | real | malformed | row | here |", "")),
		// B13-GRUPO: a Grupo-style table under a near-miss heading has no Priority header; its em-dash row and its
		// bold-tier row are both uncounted (the lower bound the sync-state WARN names).
		bl("bl-grupo-table-under-a-near-miss-heading", ln("## Reapertura 2026-07-12 — backlog A→B→C", "", "| Grupo | ID | Gap | Estado |", "|---|---|---|---|", "| — | BG24 | closed one | ✅ B9 |", "| **A** | BG20 | open one | pending |", "")),
	}
}

// s8cSyncScenarios are the sync-state fixtures of the retired status teeth.
func s8cSyncScenarios() []s3Scenario {
	return []s3Scenario{
		// B13-ERR-SURFACED: --sync-state shows the em-dash-on-an-OPEN-row WARN of the backlog parse on its own stderr.
		ss("kg-emdash-open-row-warn-reaches-sync-state-stderr", ln("# R", backlog("| — | G1 | x | pending |", rowPending), ln("## Coverage", "- Coverage metric: 0/2")), nil),
	}
}
