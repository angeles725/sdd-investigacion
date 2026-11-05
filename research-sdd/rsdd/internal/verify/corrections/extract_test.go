package corrections

import (
	"fmt"
	"strings"
	"testing"
)

// render prints the records one per line in the legacy awk program's own format, so a case reads like the
// program's output (`T 8`, `Q 5 integration soft`, `A bare 67`, `U`, `S`, `N`).
func render(recs []record) string {
	var b strings.Builder
	for _, r := range recs {
		switch r.kind {
		case kindTarget:
			fmt.Fprintf(&b, "T %s\n", r.n)
		case kindQualified:
			fmt.Fprintf(&b, "Q %s %s %s\n", r.n, r.qual, r.qkind)
		case kindAmbiguous:
			fmt.Fprintf(&b, "A %s %s\n", r.cls, r.n)
		default:
			fmt.Fprintf(&b, "%c\n", r.kind)
		}
	}
	return b.String()
}

func TestExtractRecords(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ name, text, want string }{
		{"forward", "Corrects [Block 8] §2; cf. [Block 12].\n", "T 8\n"},
		{"empty file", "", ""},
		{"no trailing newline", "> Corrects [Block 8].", "T 8\n"},
		{"adjective is not a verb", "The correct value is 5, see [Block 8].\n", ""},
		{"postfix parenthetical", "[Block 1] (the claim corrects) · [Block 11] (the rec reframes).\n", "T 1\n"},
		{"wrapped across lines", "> This block Corrects\n> [Block 8] §2.\n", "T 8\n"},
		{"blank line splits units", "Corrects it\n\n[Block 8] elsewhere\n", "U\n"},
		{"bullets split units", "- Corrects the claim\n- [Block 12] only\n- also corrects [Block 14]", "U\nT 14\n"},
		{"table rows and headings start units, plain lines continue them", "| corrects |\n| [Block 3] |\n# corrects\n[Block 4]\n", "U\nT 4\n"},
		{"conjunction ends the clause", "CORRECTS the claim, and independently corroborates [Block 5].\n", "U\n"},
		{"list", "Corrects [Block 1] and [Block 2]/[Block 3] y [Block 4].\n", "T 1\nT 2\nT 3\nT 4\n"},
		{"duplicate is emitted once, padded or not", "Corrects [Block 8] and [Block 08] and [Block 8].\n", "T 8\n"},
		{"passive", "Se corrige [Block 8].\n", "S\n"},
		{"past tense", "Aquel corrigió [Block 8]. Los autores corrigieron [Block 8].\n", "S\nS\n"},
		{"negated", "Corrects nothing in [Block 8]. no corrige [Block 9]\n", "N\nN\n"},
		{"nothing but is an exception", "Corrects nothing but [Block 8].\n", "T 8\n"},
		{"bare ref leads", "CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described\n", "A bare 67\n"},
		{"bare list then mixed", "Corrects B6 and B7 and [Block 11].\n", "A bare 6\nA bare 7\nA mixed 11\n"},
		{"gap label is not a bare ref", "Corrects B50-G6 [Block 8].\n", "A object 8\n"},
		{"qualifier lead", "Corrects `integration` [Block 5].\n", "Q 5 integration lead\n"},
		{"qualifier trailing hard", "Corrects [Block 5] of the `zz` focus.\n", "Q 5 zz hard\n"},
		{"qualifier trailing soft", "Corrects [Block 5] in `parser.c`.\n", "Q 5 parser.c soft\n"},
		{"locator", "Corrects the claim junto a [Block 16].\n", "A locator 16\n"},
		{"assumption", "corrects the assumption behind [Block 1].\n", "A assumption 1\n"},
		{"object possessive", "corrects this focus's remittance ([Block 537]/[Block 538]).\n", "A object 537\nA object 538\n"},
		{"postfix list", "[Block 50]/[Block 51] (corrige el alcance)\n", "T 50\nA list 51\n"},
		{"noun declaration", "CORRIGENDUM al [Bloque 32].\n", "T 32\n"},
		{"noun backlink", "CORRIGENDUM [Bloque 82] — see there.\n", ""},
		{"noun possessive", "see the corrigendum of [Block 33].\n", "A possessive 33\n"},
		{"noun unbound", "CORRIGENDUM: [Block 33] revises it.\n", "U\n"},
		{"word that merely contains the verb", "correctsx [Block 8] corrigeñ [Block 9]\n", "U\n"},
		{"abbreviation does not end the clause", "corrects the e.g. framing in [Block 8].\n", "T 8\n"},
		{"quote prefixes", "> > Corrects [Block 8].\n", "T 8\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := render(extract(c.text)); got != c.want {
				t.Errorf("records\n got: %q\nwant: %q", got, c.want)
			}
		})
	}
}
