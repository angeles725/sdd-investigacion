package migratebacklogs

import (
	"strconv"
	"strings"
)

// The parity cases. Every case runs against the frozen script (TestDifferential) and is recorded in
// testdata/golden/cases.json (TestGoldenReplay). Each rule of the tool has a fixture where it fires alone, so a
// mutant of that rule can only be killed by that case; divergences from the script are NOT here, they are pinned
// by divergence_test.go.

const tblHdr = "| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n"

// state is a RESEARCH-STATE body: a title, the heading and a four-column table with the given rows. Every row gets
// its own gap id (G1, G2, ...) as a real backlog has: a rewritten line that equals a neighbour is a tie that GNU diff
// may align differently from the positional diff of the port (see divergence_test.go).
func state(heading string, rows ...string) string {
	numbered := make([]string, len(rows))
	for i, r := range rows {
		numbered[i] = strings.Replace(r, "| G |", "| G"+strconv.Itoa(i+1)+" |", 1)
	}
	return "# S\n\n" + heading + "\n\n" + tblHdr + strings.Join(numbered, "\n") + "\n"
}

// brow is a four-column data row.
func brow(prio, status string) string { return "| " + prio + " | G | web | " + status + " |" }

// focusesTable is a FOCUSES.md with the registry columns Focus | Status | State.
func focusesTable(rows ...string) string {
	return "# Focuses\n\n| Focus | Status | State |\n|---|---|---|\n" + strings.Join(rows, "\n") + "\n"
}

// one is a corpus holding a single state file labelled x.
func one(name, content string) dcase {
	return dcase{name: name, files: map[string]string{"RESEARCH-STATE-x.md": content}}
}

// allReasons are the MANUAL reasons of the tool; each has a case where it fires alone (TestEveryReasonFiresAlone).
var allReasons = []string{
	"unknown-priority", "emdash-open-row", "bare-closure-word", "unknown-status-token", "malformed-row",
	"unknown-focus-status", "multiple-backlog-sections", "empty-backlog-skeleton", "non-priority-backlog-table",
	"unrecognised-backlog-heading", "unsupported-table-width cols=6",
}

func allCases() []dcase {
	var cs []dcase
	add := func(c ...dcase) { cs = append(cs, c...) }

	// the arguments and the typed states of the corpus
	add(
		dcase{name: "args-none", args: []string{}},
		dcase{name: "args-two", args: []string{"@C@", "@C@"}},
		dcase{name: "args-empty", args: []string{""}},
		dcase{name: "args-absent-dir", args: []string{"@T@/nonexistent"}},
		dcase{name: "args-a-file", files: map[string]string{"f.md": "x\n"}, args: []string{"@C@/f.md"}},
		dcase{name: "state-none-absent-input"},
		dcase{name: "state-only-focuses-is-absent-input", files: map[string]string{"FOCUSES.md": focusesTable("| a | closed | RESEARCH-STATE-a.md |")}},
		dcase{name: "state-empty-file", files: map[string]string{"RESEARCH-STATE-x.md": ""}},
		dcase{name: "state-empty-root-file", files: map[string]string{"RESEARCH-STATE.md": ""}},
		dcase{name: "state-empty-focuses", files: map[string]string{"RESEARCH-STATE-x.md": state("## Gap-backlog", brow("high", "pending")), "FOCUSES.md": ""}},
		dcase{name: "state-clean-ok", files: map[string]string{"RESEARCH-STATE-x.md": state("## Gap-backlog", brow("high", "pending"))}},
	)

	// discovery: depth, exclusions, labels, order, links
	nobacklog := "# R\n\nno backlog\n"
	add(
		dcase{name: "scan-labels", files: map[string]string{
			"RESEARCH-STATE.md": nobacklog, "RESEARCH-STATE-.md": nobacklog, "RESEARCH-STATE_u.md": nobacklog, "RESEARCH-STATE-a.md": nobacklog,
			"RESEARCH-STATE-a-b.md": nobacklog, "RESEARCH-STATE-a.b.md": nobacklog, "RESEARCH-STATEx.md": nobacklog}},
		dcase{name: "scan-depth", files: map[string]string{
			"RESEARCH-STATE-d0.md": nobacklog, "a/RESEARCH-STATE-d1.md": nobacklog, "a/b/RESEARCH-STATE-d2.md": nobacklog,
			"a/b/c/RESEARCH-STATE-d3.md": nobacklog, "a/b/c/d/RESEARCH-STATE-d4.md": nobacklog,
			"f.md": "x\n", "a/FOCUSES.md": focusesTable("| d1 | closed | RESEARCH-STATE-d1.md |"), "a/b/c/FOCUSES.md": focusesTable("| d3 | closed | x |")}},
		dcase{name: "scan-git-and-template-excluded", files: map[string]string{
			".git/RESEARCH-STATE-g.md": nobacklog, "s/.git/RESEARCH-STATE-h.md": nobacklog, "RESEARCH-STATE-t.template.md": nobacklog,
			"RESEARCH-STATE.template.md": nobacklog, "RESEARCH-STATE-k.md": nobacklog, ".git/FOCUSES.md": focusesTable("| g | closed | x |")}},
		dcase{name: "scan-byte-order", files: map[string]string{
			"a/RESEARCH-STATE-z.md": nobacklog, "a-b/RESEARCH-STATE-y.md": nobacklog, "a.b/RESEARCH-STATE-x.md": nobacklog,
			"RESEARCH-STATE-w.md": nobacklog, "B/RESEARCH-STATE-v.md": nobacklog}},
		dcase{name: "scan-focuses-order", files: map[string]string{
			"RESEARCH-STATE-a.md": nobacklog, "z/FOCUSES.md": focusesTable("| z | closed | x |"), "FOCUSES.md": focusesTable("| r | closed | x |"),
			"a/FOCUSES.md": focusesTable("| a | reabierto | x |")}},
		dcase{name: "scan-symlinked-state-file", files: map[string]string{"real.txt": nobacklog}, links: map[string]string{"RESEARCH-STATE-l.md": "real.txt"}},
		dcase{name: "scan-symlinked-dir-not-followed", files: map[string]string{"RESEARCH-STATE-a.md": nobacklog, "real/RESEARCH-STATE-in.md": nobacklog}, links: map[string]string{"link": "real"}},
		dcase{name: "scan-dangling-symlink-degraded", files: map[string]string{"RESEARCH-STATE-a.md": nobacklog}, links: map[string]string{"RESEARCH-STATE-d.md": "missing.md"}},
		dcase{name: "scan-suffix-needs-dot-md", files: map[string]string{"RESEARCH-STATE-a.md": nobacklog, "RESEARCH-STATE-xmd": nobacklog}},
		dcase{name: "scan-dangling-focuses-degraded", files: map[string]string{"RESEARCH-STATE-a.md": nobacklog}, links: map[string]string{"FOCUSES.md": "missing.md"}},
	)

	// heading: each documented near-miss alone, the canonical form, the hyphen form
	rowOK := brow("high", "pending")
	for _, h := range []struct{ name, heading string }{
		{"gap-backlog-space", "## Gap backlog"}, {"backlog", "## Backlog"}, {"backlog-de-gaps", "## Backlog de gaps"},
		{"gap-backlog-text", "## Gap-backlog prioritized"}, {"gap-backlog-text-paren", "## Gap-backlog (prioritized)x"},
		{"u2011-canon", "## Gap‑backlog"}, {"u2011-nearmiss", "## Gap‑backlog extra"}, {"u2011-canon-paren", "## Gap‑backlog (a‑b)"},
		{"mixed-case", "## GAP BACKLOG"}, {"canon-paren-ok", "## Gap-backlog (prioritized)"}, {"canon-ok", "## Gap-backlog"},
	} {
		add(one("heading-"+h.name, state(h.heading, rowOK)))
	}
	add(
		one("heading-backlog-glued-suffix", state("## Gap-backlogx", rowOK)),
		one("status-single-tilde-unknown", state("## Gap-backlog", brow("high", "~x"))),
		one("status-double-tilde-struck", state("## Gap-backlog", brow("high", "~~x~~"))),
		one("heading-line-one", "## Gap backlog\n\n"+tblHdr+rowOK+"\n"),
		one("heading-hash-not-heading", "# Gap backlog\n\n"+tblHdr+rowOK+"\n"),
		one("heading-no-table-after-near", "# S\n\n## Backlog\n\nprose only\n"),
		one("heading-h3-is-not-heading", "# S\n\n### Gap backlog\n\n"+tblHdr+rowOK+"\n"),
	)

	// skeleton
	doc := focusesTable("| d | document | RESEARCH-STATE-d.md |", "| n | active | RESEARCH-STATE-n.md |")
	add(
		one("skeleton-plain", nobacklog),
		one("skeleton-no-trailing-newline", "# R\n\nno backlog"),
		one("skeleton-after-other-sections", "# R\n\n## Stop control\n\n- done\n"),
		dcase{name: "skeleton-root-label", files: map[string]string{"RESEARCH-STATE.md": nobacklog}},
		dcase{name: "skeleton-document-focus-skipped", files: map[string]string{"RESEARCH-STATE-d.md": nobacklog, "FOCUSES.md": doc}},
		dcase{name: "skeleton-active-focus-not-skipped", files: map[string]string{"RESEARCH-STATE-n.md": nobacklog, "FOCUSES.md": doc}},
		dcase{name: "skeleton-document-root-not-skipped", files: map[string]string{"RESEARCH-STATE.md": nobacklog, "FOCUSES.md": focusesTable("| (root) | document | RESEARCH-STATE.md |")}},
		dcase{name: "skeleton-document-focus-in-subdir-skipped", files: map[string]string{"s/RESEARCH-STATE-d.md": nobacklog, "s/FOCUSES.md": doc, "FOCUSES.md": focusesTable("| d | active | RESEARCH-STATE-d.md |")}},
		dcase{name: "skeleton-focuses-in-other-dir-not-seen", files: map[string]string{"RESEARCH-STATE-d.md": nobacklog, "sub/FOCUSES.md": doc}},
		one("skeleton-priority-table-outside-backlog", "# Q\n\n## Campaign queue\n\n| Priority | Name | State |\n|---|---|---|\n| high | x | pending |\n"),
		one("skeleton-empty-section-only", "## Backlog\n"),
	)

	// document-focus lookup: exact parse, header variants
	docCase := func(name, table, label string) dcase {
		return dcase{name: name, files: map[string]string{"RESEARCH-STATE-" + label + ".md": nobacklog, "FOCUSES.md": table}}
	}
	add(
		docCase("doc-substring-not-matched", focusesTable("| delta | document | RESEARCH-STATE-delta.md |"), "ta"),
		docCase("doc-regex-metachar-not-matched", focusesTable("| abc | document | RESEARCH-STATE-abc.md |"), "a.c"),
		docCase("doc-notes-cell-not-matched", "# F\n\n| Focus | Status | State | Notes |\n|---|---|---|---|\n| zed | active | RESEARCH-STATE-zed.md | documented elsewhere |\n", "zed"),
		docCase("doc-bold-with-note", focusesTable("| real | **document** (outline) | RESEARCH-STATE-real.md |"), "real"),
		docCase("doc-matched-by-state-cell", focusesTable("| other | document | RESEARCH-STATE-m.md |"), "m"),
		docCase("doc-backtick-header", "# F\n\n| `Focus` | `Status` | State |\n|---|---|---|\n| outline | document | RESEARCH-STATE-outline.md |\n", "outline"),
		docCase("doc-estado-nombre-header", "# F\n\n| Nombre | Estado |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-slug-header", "# F\n\n| Slug | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-foco-header", "# F\n\n| Foco | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-name-header", "# F\n\n| Name | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-no-focus-column", "# F\n\n| Item | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-no-status-column", "# F\n\n| Focus | Phase |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-last-status-column-wins", "# F\n\n| Focus | Status | Status |\n|---|---|---|\n| e | document | active |\n", "e"),
		docCase("doc-status-column-first-of-two", "# F\n\n| Focus | Status | Status |\n|---|---|---|\n| e | active | document |\n", "e"),
		docCase("doc-second-table-not-registry", "# F\n\n| Focus | Status |\n|---|---|\n| a | active |\n\n| Item | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-second-table-is-registry", "# F\n\n| Item | Notes |\n|---|---|\n| a | b |\n\n| Focus | Status |\n|---|---|\n| e | document |\n", "e"),
		docCase("doc-escaped-pipe-in-row", "# F\n\n| Focus | Notes | Status |\n|---|---|---|\n| e | a\\|b | document |\n", "e"),
		docCase("doc-escaped-pipe-in-label", "# F\n\n| Focus | Status |\n|---|---|\n| e\\|f | document |\n", "e|f"),
		docCase("doc-status-with-prefix-word", focusesTable("| e | documentation | x |"), "e"),
		docCase("doc-status-uppercase", focusesTable("| e | DOCUMENT | x |"), "e"),
		docCase("doc-status-not-first-word", focusesTable("| e | (document) | x |"), "e"),
		docCase("doc-row-shorter-than-status", "# F\n\n| Focus | Notes | Status |\n|---|---|---|\n| e | document\n", "e"),
		docCase("doc-state-file-in-first-cell-not-matched", "# F\n\n| Focus | Status |\n|---|---|\n| RESEARCH-STATE-e.md | document |\n", "e"),
		docCase("doc-first-cell-blank-row-skipped", "# F\n\n| Focus | Status |\n|---|---|\n|  | document |\n", "e"),
		docCase("doc-delimiter-like-first-cell", "# F\n\n| Focus | Status |\n|---|---|\n| :-: | document |\n", ":-:"),
		docCase("doc-header-only", "# F\n\n| Focus | Status |\n", "e"),
		docCase("doc-two-rows-same-label", focusesTable("| e | active | x |", "| e | document | x |"), "e"),
	)

	// priority cells, each alone in a table of its own
	for i, p := range []string{
		"critical", "CRITICAL", "med", "MED", "Med", "**HIGH**", "**high**", "HIGH", "High", "Deferred", "LOW", "**Medium**", "~~HIGH~~", "~~low~~", "~~medium~~",
		"low (deferred)", "**low (deferred)**", "high (cross-vibra)", "med (x)", "critical (a b)", "low (note)", "deferred (x)", "high(x)", "high  (two spaces)",
		"high (a) (b)", "high ((x)", "high ()", "critical (x) ", "  critical  ", "\tmed\t",
	} {
		add(one("prio-"+strconv.Itoa(i), state("## Gap-backlog", brow(p, "pending"))))
	}
	add(
		one("prio-emdash-closed-ok", state("## Gap-backlog", brow("—", "✅ B3"), brow("—", "~~x~~"), brow("— ", "folded-in B1"))),
		one("prio-edges-first-middle-last", state("## Gap-backlog", brow("critical", "pending"), brow("high", "pending"), brow("med", "pending"), brow("high", "pending"), brow("low (deferred)", "pending"))),
		one("prio-single-row-table", state("## Gap-backlog", brow("critical", "open"))),
	)
	// unknown priorities: a count and a first line
	add(
		one("manual-unknown-priority-one", state("## Gap-backlog", brow("SES2", "pending"))),
		one("manual-unknown-priority-many", state("## Gap-backlog", brow("high", "pending"), brow("urgent", "pending"), brow("high", "pending"), brow("p1", "pending"), brow("", "pending"))),
		one("manual-unknown-priority-leaves-row", state("## Gap-backlog", brow("urgent (x)", "open"), brow("severe", "open"))),
		one("manual-unknown-priority-after-qualifier", state("## Gap-backlog", brow("urgent (x)", "pending"))),
	)

	// status cells, priority high, each alone
	for i, s := range []string{
		"open", "Open", "OPEN", "queued", "Queued", "**open**", "**queued** note", "open (x)", "open note", "  open  ", "**open",
		"pending", "pending (note)", "Pending", "pendingfoo", "requires-execution", "requires-execution x", "blocked-on-b5", "blocked-on-a/b-c", "✅ B3", "**✅ B3**", "✅",
		"~~x~~", "~~open~~", "openx", "opens",
	} {
		add(one("status-"+strconv.Itoa(i), state("## Gap-backlog", brow("high", s))))
	}
	add(
		one("status-qualifier-moved-after-open", state("## Gap-backlog", brow("high (cross)", "open note"))),
		one("status-qualifier-keeps-status-text", state("## Gap-backlog", brow("med (x)", "pending until B4"))),
		one("status-padding-kept", state("## Gap-backlog", "|   critical   |  G  |  web  |   open   |", "|\tmed\t|\tG\t|\tweb\t|\tqueued\t|")),
		one("status-no-closing-pipe", state("## Gap-backlog", "| critical | G | web | open")),
		one("status-no-closing-pipe-trailing-blanks", state("## Gap-backlog", "| critical | G | web | open   ")),
		one("status-trailing-blanks-after-pipe", state("## Gap-backlog", "| critical | G | web | open |   ")),
		one("status-indented-row", state("## Gap-backlog", "   | critical | G | web | open |")),
		one("status-pipe-in-status-after-token", state("## Gap-backlog", "| high | G | web | open and more |")),
	)
	// MANUAL status reasons
	for i, s := range []string{"covered", "Covered B1", "closed", "done", "DONE"} {
		add(one("manual-bare-closure-"+strconv.Itoa(i), state("## Gap-backlog", brow("high", s))))
	}
	for i, s := range []string{"folded", "", " ", "wontfix", "deferred", "—"} {
		add(one("manual-unknown-status-"+strconv.Itoa(i), state("## Gap-backlog", brow("high", s))))
	}
	for i, s := range []string{"pending", "open", "queued", "blocked", "requires-execution", "blocked-on-x", "Pending", "OPEN"} {
		add(one("manual-emdash-open-"+strconv.Itoa(i), state("## Gap-backlog", brow("—", s))))
	}
	add(
		one("manual-emdash-open-many", state("## Gap-backlog", brow("—", "✅"), brow("—", "pending"), brow("—", "open"))),
		one("manual-emdash-prefix-priority", state("## Gap-backlog", brow("— (x)", "open"))),
		one("manual-status-reason-and-rewrite", state("## Gap-backlog", brow("critical (q)", "folded"))),
	)

	// five-column tables: the Status cell is the last one
	five := func(name string, rows ...string) dcase {
		return one(name, "# V\n\n## Gap-backlog\n| Pr. | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n"+strings.Join(rows, "\n")+"\n")
	}
	add(
		five("five-column", "| high (x) | V1 | text | doc | open |"),
		five("five-column-edges", "| critical | V1 | t | d | open |", "| high | V2 | t | d | pending |", "| MED | V3 | t | d | queued |"),
		five("five-column-unknown", "| nope | V1 | t | d | open |"),
		five("five-column-malformed-four", "| high | V1 | t | open |"),
		five("five-column-malformed-six", "| high | V1 | t | d | e | open |"),
		one("width-six", "# W\n\n## Gap-backlog\n| Priority | A | B | C | D | E |\n|---|---|---|---|---|---|\n| high | 1 | 2 | 3 | 4 | open |\n| low | 1 | 2 | 3 | 4 | open |\n| low | 1 | 2 | 3 | 4 | open |\n"),
		one("width-three", "# W\n\n## Gap-backlog\n| Priority | Gap | Status |\n|---|---|---|\n| high | 1 | open |\n"),
		one("width-two-tables-sorted", "# W\n\n## Gap-backlog\n| Priority | Gap | Status |\n|---|---|---|\n| high | 1 | open |\n\n| Priority | A | B | C | D | E |\n|---|---|---|---|---|---|\n| high | 1 | 2 | 3 | 4 | open |\n"),
		one("width-ten-sorts-before-six", "# W\n\n## Gap-backlog\n| Priority | A | B | C | D | E | F | G | H | I |\n|---|---|---|---|---|---|---|---|---|---|\n| high | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |\n\n| Priority | A | B | C | D | E |\n|---|---|---|---|---|---|\n| high | 1 | 2 | 3 | 4 | open |\n"),
		one("width-four-and-six-in-one-section", "# W\n\n## Gap-backlog\n| Priority | Gap | Artifact | Status |\n|---|---|---|---|\n| high | 1 | 2 | open |\n"),
	)

	// malformed rows
	add(
		one("malformed-too-few-cells", state("## Gap-backlog", "| high | G | pending |")),
		one("malformed-too-many-cells", state("## Gap-backlog", "| high | G | web | x | pending |")),
		one("malformed-escaped-pipe", state("## Gap-backlog", "| high | G | a\\|b | open |")),
		one("malformed-escaped-pipe-in-header", "# S\n\n## Gap-backlog\n\n| Priority | Gap | a\\|b | Status |\n|---|---|---|---|\n| high | G | web | open |\n"),
		one("malformed-escaped-pipe-outside-backlog", "# S\n\n## Notes\n\n| a | b\\|c |\n|---|---|\n\n"+"## Gap-backlog\n\n"+tblHdr+"| high | G | web | open |\n"),
		one("malformed-many", state("## Gap-backlog", "| high | G | pending |", brow("high", "open"), "| low |", "| high | G | web | x | y |")),
		one("malformed-row-before-separator-is-silent", "# S\n\n## Gap-backlog\n\n| Sev | Gap | Artifact | Status |\n|---|---|---|---|\n| high | G | web | open |\n"),
		one("malformed-header-not-priority-before-separator", "# S\n\n## Gap-backlog\n\n| Sev | Gap |\n|---|---|\n| high | G |\n"),
		one("sep-first-cell-only", "# S\n\n## Gap-backlog\n\n| Priority | Gap | Artifact | Status |\n|:--|---|---|---|\n| critical | G | web | open |\n"),
		one("sep-with-colons", "# S\n\n## Gap-backlog\n\n| Priority | Gap | Artifact | Status |\n|:-:|:-:|:-:|:-:|\n| critical | G | web | open |\n"),
		one("sep-without-leading-pipe-is-not-a-row", "# S\n\n## Gap-backlog\n\n| Priority | Gap | Artifact | Status |\n---|---|---|---\n| critical | G | web | open |\n"),
		one("header-bold-priority", "# S\n\n## Gap-backlog\n\n| **Priority** | Gap | Artifact | Status |\n|---|---|---|---|\n| critical | G | web | open |\n"),
		one("header-prioridad", "# S\n\n## Gap-backlog\n\n| Prioridad | Gap | Artifact | Status |\n|---|---|---|---|\n| critical | G | web | open |\n"),
		one("header-p-and-pr", "# S\n\n## Backlog\n\n| P | Gap | Artifact | Status |\n|---|---|---|---|\n| critical | G | web | open |\n"),
		one("header-pr-dot", "# S\n\n## Backlog\n\n| pr. | Gap | Artifact | Status |\n|---|---|---|---|\n| critical | G | web | open |\n"),
		one("header-no-leading-pipe-first-cell", "# S\n\n## Backlog\n\n|Priority|Gap|Artifact|Status|\n|---|---|---|---|\n|critical|G|web|open|\n"),
		one("header-priority-row-repeated", state("## Gap-backlog", brow("critical", "open"), "| Priority | Gap | Artifact type / source | Status |")),
		one("table-row-before-header-priority-in-prose", "# S\n\n## Gap-backlog\n\nsome prose | not a row\n\n"+tblHdr+"| critical | G | web | open |\n"),
		one("rows-outside-backlog-untouched", "# S\n\n## Notes\n\n"+tblHdr+"| critical | G | web | open |\n\n## Gap-backlog\n\n"+tblHdr+"| critical | G | web | open |\n"),
		one("rows-after-next-heading-untouched", state("## Gap-backlog", brow("critical", "open"))+"\n## Later\n\n"+tblHdr+"| critical | G | web | open |\n"),
		one("heading-after-backlog-then-prose-row", state("## Gap-backlog", brow("critical", "open"))+"\n## Later\n| critical | G | web | open |\n"),
		one("header-only-table", "# S\n\n## Gap-backlog\n\n"+tblHdr),
		one("header-only-no-separator", "# S\n\n## Gap-backlog\n\n| Priority | Gap | Artifact | Status |\n"),
	)

	// multiple / unrecognised / non-priority sections
	add(
		one("multi-canon-then-near", "# A\n\n## Gap-backlog\n"+tblHdr+"| high | A1 | web | pending |\n\n## Backlog\n"+tblHdr+"| high | A2 | web | pending |\n"),
		one("multi-two-near", "# B\n\n## Backlog\n"+tblHdr+"| critical | B1 | web | pending |\n\n## Gap backlog\n"+tblHdr+"| high | B2 | web | pending |\n"),
		one("multi-near-then-canon", "# B\n\n## Backlog\n"+tblHdr+"| critical | B1 | web | pending |\n\n## Gap-backlog\n"+tblHdr+"| high | B2 | web | pending |\n"),
		one("multi-three-near", "# B\n\n## Backlog\n"+tblHdr+"| high | 1 | web | pending |\n\n## Gap backlog\n"+tblHdr+"| high | 2 | web | pending |\n\n## Backlog de gaps\n"+tblHdr+"| high | 3 | web | pending |\n"),
		one("multi-two-canon-both-rewritten", "# B\n\n## Gap-backlog\n"+tblHdr+"| critical | 1 | web | pending |\n\n## Gap-backlog (b)\n"+tblHdr+"| med | 2 | web | open |\n"),
		one("multi-second-near-without-table", "# B\n\n## Gap-backlog\n"+tblHdr+"| high | 1 | web | pending |\n\n## Backlog\n\nprose\n"),
		one("unrec-retro-backlog", "# R\n\n## Retro backlog\n\n"+tblHdr+"| high | R1 | web | pending |\n"),
		one("unrec-kit-backlog-notes", "# K\n\n## Kit backlog (notes)\n\n"+tblHdr+"| high | K1 | web | pending |\n"),
		one("unrec-case-insensitive", "# K\n\n## BACKLOG notes\n\n"+tblHdr+"| high | K1 | web | pending |\n"),
		one("unrec-plus-canon", "# K\n\n## Retro backlog\n\n"+tblHdr+"| high | K1 | web | pending |\n\n## Gap-backlog\n"+tblHdr+"| critical | K2 | web | pending |\n"),
		one("unrec-twice", "# K\n\n## Retro backlog\n\nx\n\n## Old backlog\n\nx\n"),
		one("nonprio-matrix", "# M\n\n## Backlog\n\n| Area | Covered |\n|---|---|\n| a | yes |\n"),
		one("nonprio-plus-priority-section-elsewhere", "# M\n\n## Backlog\n\n| Area | Covered |\n|---|---|\n| a | yes |\n\n## Gap-backlog\n"+tblHdr+"| critical | 1 | web | open |\n"),
		one("nonprio-and-unrec", "# M\n\n## Backlog\n\n| Area | Covered |\n|---|---|\n\n## Retro backlog\n\nx\n"),
		one("second-priority-table-in-section", state("## Gap-backlog", brow("critical", "open"))+"\n"+tblHdr+"| med | 2 | web | queued |\n"),
	)

	// FOCUSES.md transform
	reg := func(name string, rows ...string) dcase {
		return dcase{name: name, files: map[string]string{"RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK), "FOCUSES.md": focusesTable(rows...)}}
	}
	for i, s := range []string{
		"closed", "Closed", "CLOSED", "closed (4/4)", "**closed**", "`closed`", "[closed](x)", "reabierto", "Reabierto", "reabierto (v2)", "**reabierto** x", "*closed", "  closed  ",
	} {
		add(reg("focuses-"+strconv.Itoa(i), "| a | "+s+" | RESEARCH-STATE-a.md |"))
	}
	for i, s := range []string{
		"active", "Active", "paused", "stopped", "planned", "bootstrapping", "reopened", "document", "**active**", "active (x)",
	} {
		add(reg("focuses-known-"+strconv.Itoa(i), "| a | "+s+" | RESEARCH-STATE-a.md |"))
	}
	for i, s := range []string{"weirdo", "", "closed-ish", "(closed)", "—", "stop ped", "closedx", "reopen"} {
		add(reg("focuses-unknown-"+strconv.Itoa(i), "| a | "+s+" | RESEARCH-STATE-a.md |"))
	}
	add(
		reg("focuses-edges-first-middle-last", "| a | closed | x |", "| b | active | x |", "| c | reabierto | x |", "| d | active | x |", "| e | closed | x |"),
		reg("focuses-single-row", "| a | closed | x |"),
		reg("focuses-unknown-many", "| a | weirdo | x |", "| b | closed | x |", "| c | odd | x |"),
		dcase{name: "focuses-sibling-table-untouched", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Item | Status |\n|---|---|\n| side-note | closed |\n\n| Focus | Status | State |\n|---|---|---|\n| main | closed | RESEARCH-STATE-main.md |\n"}},
		dcase{name: "focuses-table-after-registry-untouched", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": focusesTable("| main | closed | RESEARCH-STATE-main.md |") + "\n| Item | Status |\n|---|---|\n| side-note | closed |\n"}},
		dcase{name: "focuses-backtick-header", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| `Focus` | `Status` | State |\n|---|---|---|\n| main | closed | RESEARCH-STATE-main.md |\n"}},
		dcase{name: "focuses-estado-header", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Foco | Estado |\n|---|---|\n| main | reabierto |\n"}},
		dcase{name: "focuses-no-status-column-untouched", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | Phase |\n|---|---|\n| main | closed |\n"}},
		dcase{name: "focuses-two-status-columns-last-wins", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | Status | Status |\n|---|---|---|\n| main | closed | closed |\n"}},
		dcase{name: "focuses-short-row-skipped", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | Notes | Status |\n|---|---|---|\n| main | closed\n"}},
		dcase{name: "focuses-separator-row-first-cell", files: map[string]string{"RESEARCH-STATE-main.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | Status |\n|:-:|:-:|\n| main | closed |\n"}},
		dcase{name: "focuses-escaped-pipes-kept", files: map[string]string{"RESEARCH-STATE-m1.md": state("## Gap-backlog", rowOK), "RESEARCH-STATE-d1.md": "# Migrate fixture document-focus state\n\n## Outline\nNo backlog table.\n",
			"FOCUSES.md": "# Focuses\n\n| Focus | Notes | Status | Research-State | Last |\n|---|---|---|---|---|\n| m1 | n\\|esc | closed | RESEARCH-STATE-m1.md | l |\n| m2 | n\\\\|even | reabierto | RESEARCH-STATE-m1.md | l |\n| m3 | n\\\\\\|triple | closed | RESEARCH-STATE-m1.md | l\\|esc |\n| x\\|y | n | reabierto | RESEARCH-STATE-m1.md | l |\n| x\\\\|y | n | closed | RESEARCH-STATE-m1.md | l\\\\|even |\n| m4 | n | closed \\| why | RESEARCH-STATE-m1.md | l |\n| m5 | n | reabierto | RESEARCH-STATE-m1.md | l\\|\n| d1 | n\\|esc | document | RESEARCH-STATE-d1.md | l |\n"}},
		dcase{name: "focuses-padding-kept", files: map[string]string{"RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | Status | State |\n|---|---|---|\n|   a   |   closed   | x |\n|\ta\t|\treabierto\t| x |\n   | b | closed | x |\n"}},
		dcase{name: "focuses-no-closing-pipe", files: map[string]string{"RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK),
			"FOCUSES.md": "# Focuses\n\n| Focus | State | Status\n|---|---|---\n| a | x | closed\n| b | x | reabierto   \n"}},
		dcase{name: "focuses-nested-dirs", files: map[string]string{"s/RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK), "s/FOCUSES.md": focusesTable("| a | closed | x |"), "FOCUSES.md": focusesTable("| r | reabierto | x |")}},
		dcase{name: "focuses-header-only", files: map[string]string{"RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK), "FOCUSES.md": "| Focus | Status |\n"}},
		dcase{name: "focuses-prose-only", files: map[string]string{"RESEARCH-STATE-a.md": state("## Gap-backlog", rowOK), "FOCUSES.md": "# Focuses\n\nnothing here\n"}},
	)

	// hunks: the context and the merge distance of the unified diff
	gap := func(name string, between int) dcase {
		rows := []string{brow("critical", "pending")}
		for i := 0; i < between; i++ {
			rows = append(rows, brow("high", "pending"))
		}
		rows = append(rows, brow("med", "pending"))
		return one(name, state("## Gap-backlog", rows...))
	}
	for _, g := range []int{0, 1, 2, 5, 6, 7, 8, 20} {
		add(gap("hunk-gap-"+strconv.Itoa(g), g))
	}
	filler := func(n int) []string {
		var r []string
		for i := 0; i < n; i++ {
			r = append(r, brow("high", "pending"))
		}
		return r
	}
	add(
		one("hunk-change-first-row-long-tail", state("## Gap-backlog", append([]string{brow("critical", "open")}, filler(10)...)...)),
		one("hunk-change-last-row-long-head", state("## Gap-backlog", append(filler(10), brow("critical", "open"))...)),
		one("hunk-three-separate", state("## Gap-backlog", append(append(append([]string{brow("med", "x1")}, filler(9)...), brow("critical", "x2")), append(filler(9), brow("critical", "x3"))...)...)),
		one("hunk-then-tail-skeleton-merged", "# R\n\nno backlog\nmore\nlines\nhere\nand\nhere\nnow\n"),
		one("hunk-skeleton-after-long-file", strings.Repeat("filler line\n", 30)),
		one("hunk-skeleton-after-one-line", "x\n"),
		one("hunk-skeleton-after-two-lines", "x\ny\n"),
		one("hunk-unchanged-rows-around", state("## Gap-backlog", filler(5)...)+"\n## Gap backlog\n"+tblHdr+brow("critical", "open")+"\n"),
	)

	// the corpus of the bash suite, and the one the parity suite uses
	add(dcase{name: "suite-corpus", files: map[string]string{
		"FOCUSES.md": "# Focuses\n\n| Focus | Status | State |\n|---|---|---|\n| alpha | closed (4/4) | RESEARCH-STATE-alpha.md |\n| beta | active | RESEARCH-STATE-beta.md |\n| gamma | weirdo | RESEARCH-STATE-gamma.md |\n| delta | document | RESEARCH-STATE-delta.md |\n",
		"RESEARCH-STATE-alpha.md": "# Alpha — Research State\n\n## Gap backlog\n\n" + tblHdr +
			"| critical | G1 | web | open |\n| MED | G2 | web | queued (note) |\n| low (deferred) | G3 | web | pending |\n| high (cross-vibra) | G4 | web | pending |\n| SES2 | G5 | web | pending |\n| — | G6 | web | open |\n| high | G7 | web | covered B1 |\n| **HIGH** | G8 | web | **open** |\n| high | G9 | web | folded |\n| high | G10 | web | pending |\n\n## Stop control\n\n- done\n",
		"RESEARCH-STATE-beta.md":  "# Beta — Research State\n\n## Gap-backlog (prioritized)\n\n" + tblHdr + "| high | B1 | web | pending |\n| low | B2 | web | ✅ B3 |\n",
		"RESEARCH-STATE-gamma.md": "# Gamma — Research State\n\nno backlog here\n",
		"RESEARCH-STATE-delta.md": "# Delta — Research State\n\noutline only\n",
	}})
	return cs
}
