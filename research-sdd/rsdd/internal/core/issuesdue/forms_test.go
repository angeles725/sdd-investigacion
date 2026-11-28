package issuesdue

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// The delta forms Read understands: which rows are open, whether the audit goes on, and the note that says why.
// The inputs are the form cases of internal/retro/reconcile, whose goldens pin the same verdicts against the legacy script.
func TestReadDeltaForms(t *testing.T) {
	canon := tPending + "## Proposed kit deltas\n\n"
	for _, c := range []struct {
		name, retro string
		ok          bool
		open        []string
		note        string // substring of the notes, "" = none
	}{
		{"### D<N> entries", canon + "### D1 — first delta title\n\n### D2 — second delta title\n", true, []string{"D1", "D2"}, ""},
		{"a bold entry id is not usable", canon + "### **D1** — bold id\n\n### D2 — plain id\n", true, []string{"D2"}, "only 1 of 2 '### … —' entries have a usable ID token"},
		{"no entry has a usable id token", canon + "### **D1** — bold id\n\n### **D2** — bold id\n", false, nil, "unclassifiable: delta section found but contains neither row-table rows"},
		{"numbered items under the heading", canon + "1. First numbered delta item. More text.\n2. Second numbered delta item.\n", true, []string{"1", "2"}, ""},
		{"## Delta <ID> entries", tPending + "## Delta A1 — HIGH — first title\n\nbody\n\n## Delta A2 — second title\n", true, []string{"A1", "A2"}, ""},
		{"a proposals list under an unknown heading", tPending + "## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\n1. First thing to do here.\n2. Second thing to do.\n", true, []string{"1", "2"}, ""},
		{"items found, but another unknown heading produced none", tPending + "## A. THE DEFECT\n\n### Proposals (propose-never-apply) — make it automatic\n\n1. First thing to do here.\n2. Second thing to do.\n\n## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n", true, []string{"1", "2"}, "unclassifiable: proposal-like heading found but not in a countable delta form in "},
		{"an unknown heading with no items", tPending + "## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n", false, nil, "unclassifiable: proposal-like heading found but not in a countable delta form in "},
		{"two lists sharing ids", canon + "1. one thing here.\n\n## Delta proposals\n\n1. other thing here.\n", false, nil, "unclassifiable: delta items in "},
		{"an empty canonical section with a list elsewhere", canon + "just prose\n\n### Proposals\n\n1. item one here.\n2. item two here.\n", true, []string{"1", "2"}, "unclassifiable: delta section found but it produced no items in "},
		{"an empty canonical section and nothing else", canon + "just prose\n", false, nil, "unclassifiable: delta section found but contains neither row-table rows"},
		{"the §18 honest zero", canon + "No new deltas — nothing to add.\n", false, nil, "empty-input: delta section found but contains no data rows (honest §18 zero)"},
		{"the table wins over entries", tPending + tHead + tRows("1") + "\n### D5 — an entry\n", true, []string{"1"}, ""},
		{"an unclosed fence is named and hides nothing after it", canon + "### D1 — one\n\n```\n### D2 — two\n", true, []string{"D1", "D2"}, "unclosed"},
		{"a Spanish heading", tPending + "## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n" + tHead[len("## Proposed kit deltas\n\n"):] + tRows("1", "2"), true, []string{"1", "2"}, ""},
		{"an uppercase heading", tPending + "## PROPOSED KIT DELTAS\n\n" + tHead[len("## Proposed kit deltas\n\n"):] + tRows("1"), true, []string{"1"}, ""},
		{"a numbered heading", tPending + "## 2. Proposed kit deltas\n\n" + tHead[len("## Proposed kit deltas\n\n"):] + tRows("1"), true, []string{"1"}, ""},
		{"a table without a separator row", tPending + "## Proposed kit deltas\n\n| 1 | a | x |\n| 2 | b | x |\n", true, []string{"1", "2"}, ""},
		{"header words are not ids", tPending + tHead + tRows("ID", "TOTAL", "D1"), true, []string{"D1"}, ""},
		{"rows after a blank line and an H2 are not rows", tPending + tHead + tRows("1") + "\n## Notes\n\n" + tRows("7"), true, []string{"1"}, ""},
		{"fenced rows are ignored", tPending + tHead + tRows("1") + "\n```markdown\n" + tRows("2") + "```\n", true, []string{"1"}, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := newBox(t, "retros/r.md", c.retro, "")
			var notes []string
			add := func(f string, a ...any) { notes = append(notes, fmt.Sprintf(f, a...)) }
			r, ok := Read(b.retro, "tgt", Sink{Note: add, Degrade: add, Fail: add, OutOfScope: func(l string) { add("%s", l) }})
			if ok != c.ok {
				t.Fatalf("ok = %v, want %v (notes %q)", ok, c.ok, notes)
			}
			if ok && !reflect.DeepEqual(r.OpenIDs, c.open) {
				t.Errorf("OpenIDs = %v, want %v", r.OpenIDs, c.open)
			}
			// Exactly one note, or none: a stop that goes on to a second check would say a second thing.
			if got := strings.Join(notes, "\n"); (c.note == "") != (got == "") || !strings.Contains(got, c.note) || len(notes) > 1 {
				t.Errorf("notes = %q, want exactly one containing %q", notes, c.note)
			}
		})
	}
}
