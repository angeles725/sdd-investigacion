package reconcile

// Delta forms the grammar supports, marker scope and status, and the kit layouts a retro can sit in.

func formCases() []dcase {
	canon := pending + "## Proposed kit deltas\n\n"
	return []dcase{
		{name: "form/entry-headings", retro: canon + "### D1 — first delta title\n\n**Evidence**: B1\n\n### D2 — second delta title\n", cache: sigs("target-foo", "r.md", "D1")},
		{name: "form/entry-bold-id-warns", retro: canon + "### **D1** — bold id\n\n### D2 — plain id\n", cache: ""},
		{name: "form/entry-ids-all-unusable", retro: canon + "### **D1** — bold id\n\n### [D2] — bracket id\n", cache: ""},
		{name: "form/numbered-items", retro: canon + "1. First numbered delta item. More text.\n2. Second numbered delta item.\n", cache: sigs("target-foo", "r.md", "1")},
		{name: "form/h2-delta-entries", retro: pending + "## Delta A1 — HIGH — first title\n\nbody\n\n## Delta A2 — second title\n", cache: sigs("target-foo", "r.md", "A1")},
		{name: "form/h3-proposals-list", retro: pending + "## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\n1. First thing to do here.\n2. Second thing to do.\n", cache: ""},
		{name: "form/alt-items-plus-unrec-heading-without-items", retro: pending + "## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\n1. First thing to do here.\n2. Second thing to do.\n\n## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n", cache: ""},
		{name: "form/unrec-heading-without-items", retro: pending + "## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n", cache: ""},
		{name: "form/unrec-h3-proposals-prose-only", retro: pending + "## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\nsome prose, no table rows here\n", cache: ""},
		{name: "form/spanish-heading-table", retro: pending + "## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n" + tableHead[len("## Proposed kit deltas\n\n"):] + rowsOf("1", "2"), cache: sigs("target-foo", "r.md", "2")},
		{name: "form/numbered-heading", retro: pending + "## 2. Proposed kit deltas\n\n" + tableHead[len("## Proposed kit deltas\n\n"):] + rowsOf("1"), cache: ""},
		{name: "form/summary-of-new-deltas", retro: pending + "## Summary of new deltas\n\n" + tableHead[len("## Proposed kit deltas\n\n"):] + rowsOf("1"), cache: ""},
		{name: "form/two-lists-share-ids", retro: canon + "1. one thing here.\n\n## Delta proposals\n\n1. other thing here.\n", cache: ""},
		{name: "form/canonical-empty-alt-elsewhere", retro: canon + "just prose\n\n### Proposals\n\n1. item one here.\n2. item two here.\n", cache: ""},
		{name: "form/id-with-escaped-pipe", retro: pending + tableHead + `| D\|1 | change | CLAUDE.md | B1 | fix | HIGH |` + "\n" + rowsOf("2"), cache: ""},
		{name: "form/id-with-space", retro: pending + tableHead + rowsOf("D 1", "2"), cache: sigs("target-foo", "r.md", "2")},
		{name: "form/id-with-dot", retro: pending + tableHead + rowsOf("1.5"), cache: ""},
		{name: "form/id-non-ascii", retro: pending + tableHead + rowsOf("Δ1"), cache: ""},
		{name: "form/ids-of-the-fleet", retro: pending + tableHead + rowsOf("P1", "SPKI-A", "B12", "A", "R_2"), cache: sigs("target-foo", "r.md", "P1", "A", "R_2")},
		{name: "form/header-words-are-not-ids", retro: pending + tableHead + rowsOf("ID", "TOTAL", "D1"), cache: ""},
		{name: "form/table-without-separator", retro: pending + "## Proposed kit deltas\n\n| 1 | a change | x | y | fix | LOW |\n| 2 | b change | x | y | fix | LOW |\n", cache: ""},
		{name: "form/empty-first-cell", retro: pending + tableHead + "| | nothing | x | y | fix | LOW |\n" + rowsOf("2"), cache: ""},
		{name: "form/blank-line-ends-no-table", retro: pending + tableHead + rowsOf("1") + "\ntext after\n\n" + rowsOf("2"), cache: ""},
		{name: "form/h2-ends-the-section", retro: pending + tableHead + rowsOf("1") + "\n## Notes\n\n" + rowsOf("7"), cache: ""},
		{name: "form/two-canonical-sections", retro: pending + tableHead + rowsOf("1") + "\n## Delta details\n\n" + "| # | Detail |\n|---|---|\n" + rowsOf("2"), cache: ""},
		{name: "form/fenced-rows-ignored", retro: pending + tableHead + rowsOf("1") + "\n```markdown\n" + rowsOf("2") + "```\n", cache: ""},
		{name: "form/fenced-entry-ignored", retro: canon + "### D1 — real\n\n```\n### D99 — fenced fake\n```\n\n### D2 — real two\n", cache: ""},
		{name: "form/unclosed-fence-warns", retro: canon + "### D1 — one\n\n```\n### D2 — two\n", cache: ""},
		{name: "form/unclosed-fence-in-table", retro: pending + tableHead + rowsOf("1") + "\n```\n" + rowsOf("2"), cache: ""},
		{name: "form/escaped-pipes-in-later-cells", retro: pending + tableHead + `| 1 | a \| b | x | y | fix | LOW |` + "\n", cache: sigs("target-foo", "r.md", "1")},
		{name: "form/uppercase-heading", retro: pending + "## PROPOSED KIT DELTAS\n\n" + tableHead[len("## Proposed kit deltas\n\n"):] + rowsOf("1"), cache: ""},
		{name: "form/entries-and-table-prefers-table", retro: pending + tableHead + rowsOf("1") + "\n### D5 — an entry\n", cache: ""},
	}
}

func markerCases() []dcase {
	body := "# retro\n\n" + tableHead + rowsOf("1", "2", "3", "4")
	all := sigs("target-foo", "r.md", "1", "2", "3", "4", "9")
	return []dcase{
		{name: "marker/partial-shipped-list-orphaned-reason", retro: "<!-- review-status: PARTIAL shipped: 1, 2 -->\n" + body, cache: all},
		{name: "marker/partial-dismissed-list", retro: "<!-- review-status: PARTIAL shipped: 1; DISMISSED: 2, 3 -->\n" + body, cache: all},
		{name: "marker/partial-dismissed-malformed", retro: "<!-- review-status: PARTIAL shipped: 1; DISMISSED: ; -->\n" + body, cache: all},
		{name: "marker/partial-shipped-range", retro: "<!-- review-status: PARTIAL shipped: P1-P2 -->\n# retro\n\n" + tableHead + rowsOf("P1", "P2", "P3"), cache: sigs("target-foo", "r.md", "P1", "P3")},
		{name: "marker/partial-shipped-with-notes", retro: "<!-- review-status: PARTIAL shipped: 1 (done in #12), 2 -->\n" + body, cache: ""},
		{name: "marker/partial-keyword-in-prose-is-not-partial", retro: "<!-- review-status: dismissed — P1 partial, rest wontfix -->\n" + body, cache: all},
		{name: "marker/dismissed-wins-over-partial", retro: "<!-- review-status: dismissed PARTIAL -->\n" + body, cache: all},
		{name: "marker/line-three-after-h1", retro: "# retro\n\n<!-- review-status: applied -->\n\n" + tableHead + rowsOf("1"), cache: sigs("target-foo", "r.md", "1")},
		{name: "marker/out-of-scope-after-heading", retro: "# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n\n" + tableHead + rowsOf("1"), cache: all},
		{name: "marker/out-of-scope-after-frontmatter", retro: "---\ntitle: x\n---\n<!-- review-status: applied -->\n" + body, cache: all},
		{name: "marker/indented-four-spaces-is-code", retro: "    <!-- review-status: applied -->\n" + body, cache: all},
		{name: "marker/uppercase-marker", retro: "<!-- REVIEW-STATUS: Applied -->\n" + body, cache: all},
		{name: "marker/bare-marker-without-comment", retro: "review-status: applied\n" + body, cache: all},
		{name: "marker/two-markers-first-wins", retro: "<!-- review-status: pending -->\n<!-- review-status: applied -->\n" + body, cache: all},
		{name: "marker/marker-after-other-comment", retro: "<!-- kit-retro: note -->\n<!-- review-status: applied -->\n" + body, cache: all},
		{name: "marker/status-with-trailing-text", retro: "<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n" + body, cache: all},
	}
}

func layoutCases() []dcase {
	tbl := pending + tableHead + rowsOf("1", "2")
	return []dcase{
		{name: "layout/unregistered-target-falls-back-to-basename", retro: tbl, cache: sigs("target-foo", "r.md", "1"),
			targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | elsewhere | `@BOX@/rh/elsewhere` |\n", prep: func(t tb, b *box) { mustMkdir(t, b.root+"/rh/elsewhere") }},
		{name: "layout/unregistered-structural-directory-is-refused", retro: tbl, retroDir: "rh/proj/corpus/retros",
			targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | elsewhere | `@BOX@/rh/elsewhere` |\n", prep: func(t tb, b *box) { mustMkdir(t, b.root+"/rh/elsewhere") }},
		{name: "layout/nested-corpus-retros-registered", retro: tbl, cache: sigs("target-foo", "r.md", "1"), retroDir: "rh/target-foo/corpus/retros"},
		{name: "layout/targets-md-missing", retro: tbl, noTargets: true},
		{name: "layout/targets-md-without-rows", retro: tbl, targets: "# t\n\nno table here\n"},
		{name: "layout/research-home-placeholder", retro: tbl, cache: sigs("target-foo", "r.md", "1"), retroDir: "home/rh/target-foo/retros",
			targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `$RESEARCH_HOME/rh/target-foo` |\n"},
		{name: "layout/target-name-with-whitespace-warns", retro: tbl, cache: "", targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 |  target-foo  | `@BOX@/rh/target-foo` |\n"},
		{name: "layout/retro-name-with-spaces", retro: tbl, retroFile: "my retro.md", cache: sigs("target-foo", "my retro.md", "1")},
		{name: "layout/retro-name-with-regex-characters", retro: tbl, retroFile: "r+1[a].md", cache: sigs("target-foo", "r+1[a].md", "1")},
		{name: "layout/retro-name-not-md", retro: tbl, retroFile: "r.txt", cache: sigs("target-foo", "r.txt", "2")},
	}
}
