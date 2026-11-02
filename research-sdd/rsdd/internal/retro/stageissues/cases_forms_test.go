package stageissues

import "strings"

// casesForms: the delta shapes the parser stages or refuses (old suite 13, 59-63, 77-80, 85 and the fixtures).
func casesForms() []dcase {
	var out []dcase
	for _, f := range []string{
		"canon-empty-plus-list.md", "double-backslash-pipe.md", "dup-ids.md", "escaped-pipe.md", "evidence-only.md",
		"h2-delta.md", "h3-proposals.md", "header-hyphen.md", "lessons-bullets.md", "lettered-table.md",
		"list-first-prose-second.md", "mixed-prose-and-list.md", "numbered-prose.md", "numbered-single.md",
		"rejected-h3.md", "title-edges.md", "trailing-paragraph.md", "two-canonical.md", "two-tables.md",
	} {
		c := dcase{name: "forms/fixture-" + strings.TrimSuffix(f, ".md"), fixture: f, fixturePrefix: pending + "\n"}
		out = append(out, c)
		d := c
		d.name += "-nomarker"
		d.fixturePrefix = ""
		out = append(out, d)
	}
	rows := threeRows()
	entry := func(heading string) string {
		return pending + "\n# retro\n\n## Proposed kit deltas\n\n" + heading + " D1 — Entry form delta title here\n\n**Priority**: high\n\nBody of the first entry.\n\n" +
			heading + " D2 — Second entry delta title here\n\n**Type**: fix\n\nBody of the second.\n"
	}
	out = append(out,
		dry("forms/deprecated-alias-heading", pending+"\n# retro\n\n## Summary of proposed deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("forms/spanish-heading", pending+"\n# retro\n\n## PROPUESTA de deltas al kit\n\n"+tblHdr+rows[1]+"\n"),
		dry("forms/numbered-heading", pending+"\n# retro\n\n## 3. Proposed kit deltas\n\n"+tblHdr+rows[1]+"\n"),
		dry("forms/delta-proposals-heading", pending+"\n# retro\n\n## Delta proposals\n\n"+tblHdr+rows[0]+"\n"),
		dry("forms/delta-details-heading", pending+"\n# retro\n\n## Delta details\n\n"+tblHdr+rows[0]+"\n"),
		dry("forms/summary-of-new-deltas", pending+"\n# retro\n\n## Summary of new deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("forms/deltas-nuevos", pending+"\n# retro\n\n## Deltas nuevos\n\n"+tblHdr+rows[0]+"\n"),
		dry("forms/entry-h3", entry("###")),
		dry("forms/entry-applied", strings.Replace(entry("###"), pending, applied, 1)),
		dry("forms/entry-partial-shipped-d1", strings.Replace(entry("###"), pending, "<!-- review-status: applied · a · PARTIAL — shipped: D1 -->", 1)),
		dry("forms/honest-zero", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+"\nNo kit deltas proposed this round.\n"),
		dry("forms/header-only-table", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr),
		dry("forms/section-prose-only", pending+"\n# retro\n\n## Proposed kit deltas\n\nSome prose, nothing else.\n"),
		dry("forms/hyphenated-kit-delta-heading", pending+"\n# retro\n\n## The kit-delta list\n\nprose\n"),
		dry("forms/standalone-proposals", pending+"\n# retro\n\n### Proposals\n\nprose only\n"),
		dry("forms/fenced-example-heading", pending+"\n# retro\n\n```\n## Proposed kit deltas\n"+tblHdr+rows[0]+"\n```\n\nnothing else\n"),
		dry("forms/fenced-row-ignored", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+"```\n"+rows[0]+"\n```\n"+rows[1]+"\n"),
		dry("forms/unclosed-fence-warns-once", pending+"\n# retro\n\n```\nopen forever\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"+rows[1]+"\n"),
		dry("forms/indented-fence-hides-nothing", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+"    ```\n"+rows[0]+"\n    ```\n"),
		dry("forms/crlf-file", strings.ReplaceAll(doc(pending, rows...), "\n", "\r\n")),
		dry("forms/no-trailing-newline", strings.TrimSuffix(doc(pending, rows[0]), "\n")),
		dry("forms/table-after-other-section", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n\n## Other\n\n"+tblHdr+rows[1]+"\n"),
		dry("forms/row-without-trailing-pipe", pending+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+"| 1 | delta without a closing pipe here | CLAUDE.md | B1 | fix | HIGH\n"),
		dry("forms/five-cell-row", doc(pending, "| 1 | five cell delta title here | CLAUDE.md | B1 | fix |")),
		dry("forms/two-cell-row", doc(pending, "| 1 | two cell delta title here |")),
		dry("forms/lettered-ids", doc(pending, row("SPKI-A", "lettered id delta title here", "x.md", "B1", "fix", "LOW"), row("A", "single letter id delta here", "x.md", "B1", "fix", "LOW"))),
		dry("forms/id-with-dot", doc(pending, row("1.2", "dotted id delta title here", "x.md", "B1", "fix", "LOW"))),
		dry("forms/id-with-pipe", doc(pending, row(`6\|7`, "escaped pipe in the id here", "x.md", "B1", "fix", "LOW"))),
		dry("forms/escaped-pipe-in-title", doc(pending, row("1", `title with an escaped \| pipe inside`, "x.md", "B1", "fix", "LOW"))),
		dry("forms/header-named-columns", pending+"\n# retro\n\n## Proposed kit deltas\n\n| # | Priority | Type | Evidence | Target | Proposal |\n|---|---|---|---|---|---|\n| 1 | HIGH | bug | B1 | CLAUDE.md | named column delta title |\n"),
		dry("forms/header-title-first", pending+"\n# retro\n\n## Proposed kit deltas\n\n| Delta | Priority |\n|---|---|\n| title first delta text here | HIGH |\n"),
		dry("forms/header-title-only", pending+"\n# retro\n\n## Proposed kit deltas\n\n| # | Title |\n|---|---|\n| 1 | only a title column here |\n"),
		dry("forms/header-no-title-column", pending+"\n# retro\n\n## Proposed kit deltas\n\n| # | Foo | Bar | Baz |\n|---|---|---|---|\n| 1 | positional reading of delta | CLAUDE.md | B1 |\n"),
		dry("forms/single-data-row-no-type", pending+"\n# retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target |\n|---|---|---|\n| 1 | a single row without a type | CLAUDE.md |\n"),
		dry("forms/header-escaped-pipe", pending+"\n# retro\n\n## Proposed kit deltas\n\n| # | Proposed change \\| and more | Target |\n|---|---|---|\n| 1 | header with an escaped pipe | CLAUDE.md |\n"),
		dry("forms/separator-as-first-line", pending+"\n# retro\n\n## Proposed kit deltas\n\n|---|---|---|\n| 1 | data row directly above separator | x |\n|---|---|---|\n"),
		dry("forms/alt-numbered-under-heading", pending+"\n# retro\n\n## Proposed kit deltas\n\n1. First numbered delta title in prose form.\n2. Second numbered delta title in prose form.\n"),
		dry("forms/alt-delta-entries", pending+"\n# retro\n\n## Delta A — HIGH — Alt entry delta title here\n\nbody a\n\n## Delta B — Alt entry second title here\n\nbody b\n"),
	)
	return out
}

// casesTitles: titles, labels, wrong-kit rows (old suite 4, 6, 7, 12, 14, 15, 85e-85j).
func casesTitles() []dcase {
	long := strings.Repeat("abcdefghi ", 14)
	return []dcase{
		dry("titles/two-rows-labels", doc(pending, threeRows()...)),
		dry("titles/no-priority-dash", doc(pending, row("1", "no priority delta title here", "x.md", "B1", "fix", "—"))),
		dry("titles/priority-case", doc(pending, row("1", "high priority delta title", "x.md", "B1", "fix", "high"), row("2", "medium priority delta title", "x.md", "B1", "fix", "Medium"), row("3", "weird priority delta title", "x.md", "B1", "fix", "urgent"))),
		dry("titles/type-mapping", doc(pending,
			row("1", "type new delta title here", "x.md", "B1", "new", "LOW"), row("2", "type fix delta title here", "x.md", "B1", "fix", "LOW"),
			row("3", "type doc delta title here", "x.md", "B1", "doc", "LOW"), row("4", "type docs delta title here", "x.md", "B1", "Documentation", "LOW"),
			row("5", "type bug delta title here", "x.md", "B1", "BUG", "LOW"), row("6", "type regression title here", "x.md", "B1", "regression", "LOW"),
			row("7", "type docfix delta title here", "x.md", "B1", "doc-fix", "LOW"), row("8", "type defect delta title here", "x.md", "B1", "defect", "LOW"),
			row("9", "type empty delta title here", "x.md", "B1", "", "LOW"))),
		dry("titles/wrong-kit-row", doc(pending, row("1", "wrong kit delta title here", "niagara-kit:CLAUDE.md", "B1", "fix", "LOW"), row("2", "right kit delta title here", "CLAUDE.md", "B1", "fix", "LOW"))),
		dry("titles/wrong-kit-slash", doc(pending, row("1", "wrong kit slash delta here", "other-kit/x.md", "B1", "fix", "LOW"))),
		dry("titles/wrong-kit-only-all-shipped-mix", doc("<!-- review-status: applied · a · PARTIAL — shipped: 2 -->", row("1", "wrong kit delta title here", "z-kit:x", "B1", "fix", "LOW"), row("2", "shipped delta title here", "x.md", "B1", "fix", "LOW"))),
		dry("titles/bold-lead-in", doc(pending, row("1", "**Bold phrase.** detail text follows the phrase", "x.md", "B1", "fix", "LOW"))),
		dry("titles/bold-only-open", doc(pending, row("1", "**Only an opening bold marker here", "x.md", "B1", "fix", "LOW"))),
		dry("titles/bold-wrapping", doc(pending, row("1", "**wrapped bold title text**", "x.md", "B1", "fix", "LOW"))),
		dry("titles/plain-cell", doc(pending, row("1", "plain cell no markers at all", "x.md", "B1", "fix", "LOW"))),
		dry("titles/short-title", doc(pending, row("1", "short one", "x.md", "B1", "fix", "LOW"))),
		dry("titles/eleven-chars", doc(pending, row("1", "abcdefghijk", "x.md", "B1", "fix", "LOW"))),
		dry("titles/twelve-chars", doc(pending, row("1", "abcdefghijkl", "x.md", "B1", "fix", "LOW"))),
		dry("titles/token-title", doc(pending, row("1", "HIGH", "x.md", "B1", "fix", "LOW"), row("2", "doc-fix", "x.md", "B1", "fix", "LOW"), row("3", "  Bugfix  ", "x.md", "B1", "fix", "LOW"))),
		dry("titles/empty-title", doc(pending, row("1", "", "x.md", "B1", "fix", "LOW"))),
		dry("titles/over-120-ascii", doc(pending, row("1", long, "x.md", "B1", "fix", "LOW"))),
		dry("titles/exactly-120", doc(pending, row("1", strings.Repeat("a", 120), "x.md", "B1", "fix", "LOW"))),
		dry("titles/121", doc(pending, row("1", strings.Repeat("a", 121), "x.md", "B1", "fix", "LOW"))),
		dry("titles/eleven-multibyte-chars", doc(pending, row("1", strings.Repeat("ñ", 11), "x.md", "B1", "fix", "LOW"))),
		dry("titles/twelve-multibyte-chars", doc(pending, row("1", strings.Repeat("ñ", 12), "x.md", "B1", "fix", "LOW"))),
		dry("titles/latin1-bytes", doc(pending, row("1", "caf\xe9 caf\xe9 caf\xe9 caf\xe9", "x.md", "B1", "fix", "LOW"))),
		dry("titles/latin1-continuation-range", doc(pending, row("1", "\xb0\xb0\xb0\xb0\xb0\xb0\xb0\xb0\xb0\xb0\xb0\xb0", "x.md", "B1", "fix", "LOW"))),
		dcase{name: "titles/multibyte-over-120-utf8", retro: doc(pending, row("1", strings.Repeat("é", 125), "x.md", "B1", "fix", "LOW")), locale: "C.UTF-8"},
		dcase{name: "titles/multibyte-120-utf8", retro: doc(pending, row("1", strings.Repeat("é", 120), "x.md", "B1", "fix", "LOW")), locale: "C.UTF-8"},
		dcase{name: "titles/multibyte-over-120-c", retro: doc(pending, row("1", strings.Repeat("é", 125), "x.md", "B1", "fix", "LOW"))},
		dcase{name: "titles/invalid-utf8-over-120-utf8", retro: doc(pending, row("1", strings.Repeat("\xe9", 125), "x.md", "B1", "fix", "LOW")), locale: "C.UTF-8"},
		dcase{name: "titles/short-multibyte-utf8", retro: doc(pending, row("1", strings.Repeat("é", 11), "x.md", "B1", "fix", "LOW")), locale: "C.UTF-8"},
		dry("titles/body-fields", doc(pending, row("1", "delta with evidence and target", "tool/x.sh and y.md", "B7: evidence text", "fix", "LOW"))),
		dry("titles/evidence-only-cell-empty", doc(pending, row("1", "delta with empty target cell", "", "", "", ""))),
	}
}
