package grammar

import (
	"math/rand"
	"strings"
)

// genVocab is the line vocabulary of the generated differential corpus: every heading alias, near-miss heading,
// row, field, numbered item, honesty variant, fence and byte edge (CR, NBSP, em-dash, non-ASCII, invalid UTF-8)
// the grammar distinguishes. Random documents over it reach state combinations no hand fixture names.
var genVocab = []string{
	// canonical, deprecated and near-miss headings
	"## Proposed kit deltas", "## 6. Proposed kit delta", "## Proposed kit deltasx", "## proposed deltas extra",
	"## Delta proposals", "## Deltas NUEVOS", "## PROPUESTA de deltas al kit", "## propuesta de deltas al kitx",
	"## Summary of proposed deltas", "## Summary of new deltas", "## Delta details", "## Delta detailsx",
	"## Proposed kit deltas\r", "##\tProposed kit deltas", "## Honest verdict", "## 2. Honest verdict",
	"## Honest verdicts", "## Other section", "##", "###", "#### deep heading", "# D1", "# 1 top", "# Title",
	// H2 delta-intent forms
	"## Delta D1 — Add the thing", "## Delta R2 — HIGH — fix it", "## Delta SPKI-A — MED — hyphen id",
	"## Delta W3 — low — lower level", "## DELTA D3 — upper", "## Delta ID — not an id", "## Delta D4 —",
	"## Delta ABCDEFGH1 — too long", "## deltas (x)", "## 3. delta", "## 1. deltas: more", "## delta",
	"## B. Campaign-8 kit-delta backlog", "## not kit-delta", "## The (kit-delta list)", "## kit delta",
	"## D1 thing", "## Proposed", "## Deltas", "## A12: veto",
	// H3 forms
	"### Proposals (propose-never-apply) — x", "### 1. Proposals", "### Proposal", "###  proposals:", "### Proposalsx",
	"### D1 — Add a thing (high)", "### D2. — Fix: (new, priority: Medium)", "### D3: — (low-risk change)",
	"### **D4** — bold id", "### [D5] — bracket id", "### D6 —", "### — no id", "### D7 no dash",
	"### Considered and rejected", "### Delta x", "### Proposed y", "### D8 — (Low) (High)", "### d9_x — t (LOW)",
	// table rows
	"| ID | Proposed change | Target |", "|---|---|---|", "|:--|--:|", "| --- | :-: |  ", "| # | Delta | Where |",
	"| D1 | Add **bold** title here please | lib/x |", "| D2 | a\\| b | c |", "| x\\\\| y | z |",
	"| SPKI-A | hyphen id title long | t |", "| ITEM-ID | header-ish | t |", "| 1 | numeric row title text | t |",
	"| a | lowercase |", "|  | empty id |", "| D 1 | spaced |", "| D1.x | dotted id |", "| D9 | crlf row |\r",
	"| Rule / change | Gist |", "| R7 | **Bold** rest | x |", "| B12 |", "| D3 | no trailing pipe", "|",
	// entry fields
	"**Priority**: HIGH — fires", "**Priority:** medium", "**Priority**: 1", "**priority** low, maybe",
	"**Where in kit**: lib/a.sh", "**Kit file**: x  ", "**Target**: y", "**Evidence**: seen 3x",
	"**Other evidence** z", "**Bold** only", "**Priority evidence**: q",
	// numbered items and PROPOSED targets
	"1. **Title one.** prose follows", "2) Plain sentence here. Next one", "3. e.g. something. Then More",
	"4. lower. then more. Done here", "5. **unclosed bold title", "6.  ", "7. A. B. C. D",
	"8. " + strings.Repeat("ab ", 30) + "é" + strings.Repeat("x", 20), "9. " + strings.Repeat("evidence ", 50),
	"   indented PROPOSED lib/x.sh: change", "PROPOSED target: x", "PROPOSED no colon", "12) twelve: item.",
	// honesty lines, lead-block markers
	"No new deltas; the kit already covers this run.", "- **No new deltas — nothing to add.**",
	"> No new deltas; nothing to add.", "_no new deltas; nothing to add._", "no new deltas; nothing to add. extra",
	"__No new deltas — the kit already covers this run.__", "* + > no new deltas; nothing to add.",
	"> guidance prose", "> - bullet in quote", "> 1. numbered", ">  - nbsp bullet", "> • dot", "> [x] box",
	"> a) letter", "> > nested - x", "> — dash continuation", "> ## heading", "> | pipe", ">",
	// fences
	"```", "~~~", "```py", "````", "    ```", "```a`b", "  ~~~~", "``` \r",
	// prose and byte edges
	"", "   ", "\t", "plain text", "text\r", "<!-- comment -->", "É accented line", "\xff\xfe invalid",
}

// generatedDocs returns n deterministic documents (fixed seed) of 1 to 40 vocabulary lines.
func generatedDocs(n int) []string {
	r := rand.New(rand.NewSource(2286))
	docs := make([]string, n)
	for i := range docs {
		k := 1 + r.Intn(40)
		lines := make([]string, k)
		for j := range lines {
			lines[j] = genVocab[r.Intn(len(genVocab))]
		}
		docs[i] = strings.Join(lines, "\n")
		if r.Intn(4) > 0 {
			docs[i] += "\n"
		}
	}
	return docs
}
