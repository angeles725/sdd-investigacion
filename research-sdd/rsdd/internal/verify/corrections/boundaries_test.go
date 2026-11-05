package corrections

import "testing"

// backlinkVerdict runs a corpus where t-block82 corrects block 21 and block 21 carries note: exit 0 when the note
// is accepted as the reciprocal backlink, 1 when it is not.
func backlinkVerdict(t *testing.T, note string) int {
	t.Helper()
	return runCorpus(t, files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "# 21\n\nOriginal.\n\n"+note+"\n")).code
}

func TestVocabularyBoundaries(t *testing.T) {
	t.Parallel()
	for _, p := range []string{"—", "–", "‘", "’", "“", "”", "«", "»", "¿", "¡", "·"} {
		t.Run("left boundary "+p, func(t *testing.T) {
			if got := backlinkVerdict(t, p+"corrected in B82"); got != 0 {
				t.Errorf("%q before the vocabulary must be a word boundary", p)
			}
		})
	}
	for _, c := range []struct {
		note string
		want int
	}{
		{"refinement (B82): narrower.", 0}, // `refinement (` without the §14 prefix
		{"refinement B82", 1},              // the parenthesis is part of the word
		{"Refinamiento §14 de B82", 0},     // `refinamiento §14`
		{"refinamiento (B82)", 0},          // `refinamiento (`
		{"refinamiento de B82", 1},         // neither a parenthesis nor §14
		{"§14 refinement of B82", 0},       // `§14 refinement`
		{"corrected in éB82", 1},           // a letter right before B<n> is word text
		{"corrected in B82é", 1},           // a letter right after the number is word text
		{"corrected in ñB82", 1},           // another multi-byte letter before
		{"corrected in B82 é", 0},          // a space separates it
		{"écorrected in B82", 1},           // a letter before the vocabulary word
		{"corrected in B82_", 0},           // markdown italics close with `_` (intended difference D5)
		{"corrected in _B82", 1},           // `_` before is word text for the block reference
		{"corrected in B82, B83", 0},       // a list
		{"corrected in B82\tand B83", 0},   // tab separated
		{"Corrected in 82", 1},             // no B / Block prefix
		{"corrected in [Block 82]", 0},     // bracketed form
		{"corrected in Block 82", 0},       // spelled form
		{"corrected in Bloque 82", 0},      // Spanish form
		{"corrected in B82", 0},            // a no-break space is not word text
		{"x_corrected in B82", 0},          // `_` is a left boundary of the vocabulary (markdown italics)
	} {
		t.Run(c.note, func(t *testing.T) {
			if got := backlinkVerdict(t, c.note); got != c.want {
				t.Errorf("%q: exit %d, want %d", c.note, got, c.want)
			}
		})
	}
}
