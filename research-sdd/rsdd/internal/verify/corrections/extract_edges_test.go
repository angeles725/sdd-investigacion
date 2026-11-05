package corrections

import (
	"strings"
	"testing"
)

// edgeCases pin the boundaries of the extractor: each text sits on the edge of one comparison, offset or
// bracket-depth rule. The expectations are the legacy program's (TestDifferentialEdgeCases runs the same texts through
// the frozen script).
var edgeCases = []struct{ name, text, want string }{
	// the position of the first bare B<N> after a skipped gap label decides between the bare ref and the bracketed one
	{"bare after a gap label and the ref", "Corrects b12345-g1 [Block 3] B9.\n", "A object 3\n"},
	{"bare list after a skipped gap label", "Corrects b1-g1 b9 and b8.\n", "A bare 9\nA bare 8\n"},
	{"bare before the ref wins", "Corrects B9 [Block 3].\n", "A bare 9\n"},
	{"bare after the ref loses", "Corrects [Block 3] B9.\n", "T 3\n"},
	// a postfix verb: the first ref of a joined list, and the list head is never walked past index 1
	{"postfix verb after a joiner word", "y [Block 5] (corrects it)\n", "T 5\n"},
	{"postfix list", "[Block 4] y [Block 5] (corrects it)\n", "T 4\nA list 5\n"},
	{"postfix list of three", "[Block 3] y [Block 4] y [Block 5] (corrects it)\n", "T 3\nA list 4\nA list 5\n"},
	// negation words that do not negate
	{"no longer is not a negation", "Corrects no longer in [Block 8].\n", "T 8\n"},
	{"no claim is", "Corrects no claim in B402.\n", "N\n"},
	// a qualifier whose token is the word focus is a soft one: only a `focus` OUTSIDE the backticks makes it hard
	{"focus inside the backticks", "Corrects [Block 5] of `focus`.\n", "Q 5 focus soft\n"},
	{"focus outside the backticks", "Corrects [Block 5] of the `zz` focus.\n", "Q 5 zz hard\n"},
	{"qualifier after a joined list", "Corrects [Block 1] and [Block 2] of `zz`\n", "Q 1 zz soft\nQ 2 zz soft\n"},
	// a corrigendum tag is short up to tagMax bytes
	{"tag of exactly tagMax bytes", "CORRIGENDUM [" + strings.Repeat("x", tagMax) + "] al [Bloque 32]\n", "T 32\n"},
	{"tag of tagMax+1 bytes", "CORRIGENDUM [" + strings.Repeat("x", tagMax+1) + "] al [Bloque 32]\n", "U\n"},
	// parenthesis depth in the clause: an unmatched ) ends it, a matched pair does not
	{"matched pair then a stray close", "Corrects (x) ) [Block 8].\n", "U\n"},
	{"matched nested pairs", "Corrects (x (y) z) [Block 8].\n", "T 8\n"},
	{"close with no opener behind", "see Corrects x) [Block 3]\n", "U\n"},
	{"verb inside its own parenthesis", "(Corrects [Block 1])\n", "T 1\n"},
	// the byte after a corrig* verb: 0-9, _ and 0x80+ are word text, the rest end the word
	{"verb then 0", "Corrige0 [Block 1].\n", "U\n"},
	{"verb then 9", "Corrige9 [Block 1].\n", "U\n"},
	{"verb then / (0x2f)", "Corrige/ [Block 1].\n", "T 1\n"},
	{"verb then : (0x3a)", "Corrige: [Block 1].\n", "T 1\n"},
	{"verb then _", "Corrige_ [Block 1].\n", "U\n"},
	{"verb then DEL (0x7f)", "Corrige\x7f [Block 1].\n", "T 1\n"},
	{"verb then 0x80", "Corrige\x80 [Block 1].\n", "U\n"},
	{"verb then a UTF-8 dash", "Corrige\xe2\x80\x94 [Block 1].\n", "U\n"},
}

func TestEdgeCases(t *testing.T) {
	t.Parallel()
	for _, c := range edgeCases {
		t.Run(c.name, func(t *testing.T) {
			if got := render(extract(c.text)); got != c.want {
				t.Errorf("extract(%q) =\n%swant\n%s", c.text, got, c.want)
			}
		})
	}
}
