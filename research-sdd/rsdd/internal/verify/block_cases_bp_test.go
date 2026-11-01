//go:build unix

package verify

import (
	"os"
	"path/filepath"
	"testing"
)

// Back-pointer cases (section 14): the sentence scanner's filters, the confidence grading, the resolution of
// the cited block file and the typed non-verdicts.

func bpCorpus(extra map[string]string) map[string]string {
	m := map[string]string{
		"c/kit-block1.md":   q("# Block 1\nold one\n"),
		"c/kit-block2.md":   q("# Block 2\nsee B9 for the follow-up\n"),
		"c/kit-block3.md":   q("# Block 3\nnothing back\n"),
		"c/kit-block4.md":   q("# Block 4\nrefs Block 9 here\n"),
		"c/kit-block5.md":   q("# Block 5\nrefs Bloque 9 here\n"),
		"c/kit-block6.md":   q("# Block 6\nB09x B90 xB9 5.9 B9a\n"),
		"c/kit-block7.md":   q("# Block 7\nB009 is mentioned\n"),
		"c/kit-block11.md":  q("# Block 11\n"),
		"c/other-block3.md": q("# Block 3 (other)\nBlock 9\n"),
		"c/x-block8.md":     q("# Block 8\n"),
	}
	for k, v := range extra {
		m[k] = v
	}
	return m
}

// bpCase builds the corpus c/ around the checked block kit-block9.md; opts are a map of extra files and/or
// string arguments appended after the block path.
func bpCase(name, selfBody string, opts ...any) blockCase {
	var extra map[string]string
	args := []string{"c/kit-block9.md"}
	for _, o := range opts {
		switch x := o.(type) {
		case map[string]string:
			extra = x
		case string:
			args = append(args, x)
		}
	}
	files := bpCorpus(extra)
	files["c/kit-block9.md"] = q(selfBody)
	return blockCase{name: name, files: files, args: args}
}

func backptrCases() []blockCase {
	var cs []blockCase
	add := func(c ...blockCase) { cs = append(cs, c...) }
	sentences := []string{
		"This block corrects Block 1.", "This block corrects [Block 2].", "Corrige el Bloque 3.", "Esto refuta B4.", "supersedes Block 5 entirely.",
		"The correction of Block 1 is here.", "Corrección al Bloque 2 sobre eso.", "It corrected Block 1.", "This corrects the earlier claim about B1 in a long way that goes on",
		"Block 1 is corrected by Block 3.", "Corregido en Block 1: see below.", "already corrected Block 1 earlier.", "Block 1 was corrected.", "Block 1 was refuted by us.",
		"It is not a correction of Block 1.", "No §14 correction of Block 1 here.", "Nothing here refutes Block 1.", "without correcting Block 1.", "corrects nothing in Block 1.",
		"not only corrects Block 1 but also more", "not just refutes Block 1", "no correction to Block 1.", "ninguna corrección de Block 1.", "no refutes Block 1",
		"The corrigendum for Block 1 is below.", "A corrigendum corrects Block 1.", "self-correction of Block 1 remarks", "autocorrect for Block 1", "autocorrection and Block 1",
		"The correct template for Block 1.", "correctly handled in Block 1", "correcto en Block 1", "It correcting Block 1", "Superseded by Block 1.",
		"Corrects Block 1 and Block 2.", "Corrects Block 1, Block 2 and Block 3.", "Connects [Block 1] · [Block 2] corrected", "Related: Block 1 and Block 2 corrected.", "see also Block 1, Block 2: corrected",
		"Corrects Block 1 · and Block 2 · here · now", "corrects Block 9 itself.", "corrects Block 10 forward.", "corrects Block 8.", "corrects Block 99 and 100",
		"corrects B1.", "corrects block1.", "corrects bloque1 now", "corrects Block1.", "corrects AB1 and xB1", "corrects B1x", "corrects B1_ and B_1",
		"corrects R1", "corrects Block R1", "corrects Block R 1", "corrects [Block 01]", "corrects Block 001", "corrects Block 1 Block 1 Block 1",
		"corrects Block 1; and also Block 2? no", "corrects. Block 1.", "Block 1! corrects.", "Block 1. Corrects Block 3. Refutes Block 4",
		"[Block 2] — corregido en B3", "[Block 2] §14 correction", "[Block 2] §95.9 correction", "[Block 2] supersedes it", "[Block 2] — correction",
		"corrected by B3", "corrected in Block 3", "corregido en [Block 3]", "refutado por Bloque 3", "superseded by (B3)", "corrected by *B3*", "corrected  by  [(*Block 3",
		"refutes the old claim which was long and wandering around many words ahead of Block 1", "far far away from correction we still mention Block 1 here and now ok ok ok ok ok ok ok",
		"corrects with exactly twenty five chars padding Block 1", "corrects ----Block 1", "corrects                         Block 1",
		"Corrects: B1; corrects B2", "CORRECTS BLOCK 1", "Corrects block 1", "Corrects bloque 1", "refut* Block 1", "supersedes: Block 1", "it superseded Block 1.",
		"corrects B1 é ü B2 · x", "ünïcode corrects Block 1 ünï", "É corrects Block 1", "corrects Block 1 — a long é dash — and more é words", "correct(s) Block 1",
	}
	for i, s := range sentences {
		add(bpCase("bp-s-"+itoa(i), "# Block 9\n\n"+s+"\n"))
	}
	add(
		bpCase("bp-all-high", "# Block 9\n\nCorrects Block 1.\nCorrects B1.\nsee also Block 3 corrects.\n", "--backptr=all"),
		bpCase("bp-off", "# Block 9\n\nCorrects Block 1.\n", "--backptr=off"),
		bpCase("bp-subdir-not-searched", "# Block 9\n\nCorrects Block 1.\n", map[string]string{"c/sub/kit-block1.md": q("# Block 1\nB9\n"), "c/sub/deep/kit-block1.md": q("# Block 1\n")}),
		bpCase("bp-high-explicit", "# Block 9\n\nCorrects Block 1. Corrects B3.\n", "--backptr=high"),
		bpCase("bp-all-low-listed", "# Block 9\n\nIt corrects the claim in B1 somewhat.\n", "--backptr=all"),
		bpCase("bp-low-counted", "# Block 9\n\nIt corrects the claim in B1 somewhat.\n"),
		bpCase("bp-ok-and-missing", "# Block 9\n\nCorrects Block 2. Corrects Block 1.\n"),
		bpCase("bp-ok-forms", "# Block 9\n\nCorrects Block 2. Corrects Block 4. Corrects Block 5. Corrects Block 7. Corrects Block 6.\n"),
		bpCase("bp-prefix-same-first", "# Block 9\n\nCorrects Block 3.\n"),
		bpCase("bp-ambiguous", "# Block 9\n\nCorrects Block 3.\n", map[string]string{"c/kit-block03.md": q("# Block 3b\n")}),
		bpCase("bp-notfound", "# Block 9\n\nCorrects Block 50.\n"),
		bpCase("bp-notfound-low", "# Block 9\n\nIt corrects the claim in B50 somewhat.\n"),
		bpCase("bp-multi-paragraph", "# Block 9\n\nFirst para corrects\nBlock 1 across lines.\n\n- item corrects Block 3\n- item two\n\n1. numbered corrects B4\n\n| t | corrects B2 |\n"),
		bpCase("bp-heading-corrects", "# Block 9 corrects Block 1\n\n## and corrects B3\n"),
		bpCase("bp-fence-skipped", "# Block 9\n\n```\ncorrects Block 1\n```\n\nafter corrects Block 3\n"),
		bpCase("bp-maxconf-upgrade", "# Block 9\n\nIt corrects the claim in B1 somewhat.\n\nCorrects Block 1.\n"),
		bpCase("bp-maxconf-keep", "# Block 9\n\nCorrects Block 1.\n\nIt corrects the claim in B1 somewhat.\n"),
		bpCase("bp-dup-same-sentence", "# Block 9\n\nCorrects Block 1 and also [B1] but not B2.\n"),
		bpCase("bp-no-heading", "Corrects Block 1.\n"),
		bpCase("bp-tab-and-quote-excerpt", "# Block 9\n\nCorrects\tBlock 1 with \"quotes\" and\ttabs.\n"),
		bpCase("bp-long-excerpt", "# Block 9\n\nCorrects Block 1 "+repeat("very long sentence ", 20)+" end.\n"),
		bpCase("bp-long-excerpt-unicode", "# Block 9\n\nCorrects Block 1 "+repeat("é", 150)+" end.\n"),
		bpCase("bp-leading-space-excerpt", "# Block 9\n\n   Corrects Block 1 indented.\n"),
		bpCase("bp-target-other", "# Block 9\n\nCorrects Block 1.\n", map[string]string{"t/kit-block1.md": q("# Block 1\nB9\n")}, "c/kit-block9.md-unused"),
	)
	// the explicit target is a different directory holding the cited block
	tgt := bpCase("bp-target-dir", "# Block 9\n\nCorrects Block 1. Corrects Block 20.\n", map[string]string{"t/kit-block20.md": q("# Block 20\nBlock 9 is here\n")})
	tgt.args = []string{"c/kit-block9.md", "t"}
	tgt2 := bpCase("bp-target-same", "# Block 9\n\nCorrects Block 1.\n")
	tgt2.args = []string{"c/kit-block9.md", "c/"}
	tgt3 := bpCase("bp-target-missing-dir", "# Block 9\n\nCorrects Block 1.\n")
	tgt3.args = []string{"c/kit-block9.md", "nowhere"}
	add(tgt, tgt2, tgt3)

	// the R series: a block whose H1 is `# Block R<n>`
	rfiles := map[string]string{
		"c/kit-block5.md": q("# Block R5\nold r five\n"), "c/other-block5.md": q("# Block 5\nold numeric\nBlock 9 here\n"),
		"c/kit-block6.md": q("# Block R6\nR9 points back\n"), "c/kit-block7.md": q("# Block R7\nBlock R9 points back\n"),
		"c/kit-block8.md": q("# Block 8\nR9 is a register, B9 is not\n"),
	}
	add(
		bpCase("bp-r-series", "# Block R9\n\nCorrects R5.\nCorrects Block R6.\nCorrects R7.\nCorrects Block R7.\nCorrects Block 8.\n", rfiles),
		bpCase("bp-r-bare-in-n", "# Block 9\n\nCorrects R5 and Block R6.\n", rfiles),
		bpCase("bp-r-forward", "# Block R9\n\nCorrects R10. Corrects Block R9. Corrects Block 10. Corrects B3.\n", rfiles),
		bpCase("bp-r-heading-not-first", "intro\n# Block R9\n\nCorrects R5.\n", rfiles),
		bpCase("bp-r-second-heading", "# Block 9\n\n# Block R9\n\nCorrects R5.\n", rfiles),
		bpCase("bp-r-numeric-cite-in-r", "# Block R9\n\nCorrects Block 5. Corrects B5.\n", rfiles),
		bpCase("bp-r-series-pick", "# Block R9\n\nCorrects Block R5.\n", map[string]string{"c/kit-block5.md": q("# Block R5\n"), "c/aa-block5.md": q("# Block 5\n")}),
	)

	// names: the checked block's own name decides whether the check runs
	for i, n := range []string{"block9.md", "kit-block9.md", "kit-bloque9.md", "kit-block9-slug.md", "kit-block9-a_b-c.md", "a-b-block009.md", "kit-block9-slug.txt", "kit-block.md", "kit-block9x.md", "Kit-Block9.md", "kit-block9-é.md", "block9-block10.md", "x-block1-block9.md", "-block9.md", "kit--block9.md", "kit-block9-.md"} {
		add(blockCase{name: "bp-name-" + itoa(i), files: bpCorpus(map[string]string{"c/" + n: q("# Block 9\n\nCorrects Block 1.\n")}), args: []string{"c/" + n}})
	}
	// unreadable cited block, unreadable scan directory
	un := bpCase("bp-unreadable-cited", "# Block 9\n\nCorrects Block 1.\n")
	un.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "c", "kit-block1.md")); err != nil {
			t.Fatal(err)
		}
	}
	un2 := bpCase("bp-unreadable-dir", "# Block 9\n\nCorrects Block 1. Corrects Block 20.\n", map[string]string{"t/kit-block20.md": q("# Block 20\n")})
	un2.args = []string{"c/kit-block9.md", "t"}
	un2.setup = func(t testing.TB, root string) {
		if os.Getuid() == 0 {
			return
		}
		if err := deny(t, filepath.Join(root, "t")); err != nil {
			t.Fatal(err)
		}
	}
	add(un, un2)
	return cs
}
