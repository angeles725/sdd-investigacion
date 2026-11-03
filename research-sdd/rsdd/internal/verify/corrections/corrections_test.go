package corrections

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// Rule tests of `verify corrections`, through the public entry point on a real directory. Each case names the
// rule it pins; the ones that mirror a legacy shell case carry its number. The legacy-parity of every rule is
// proven separately by the differential tests (differential_test.go), which compare the whole report.

// blk names a block file `<prefix>-block<num>.md`.
func blk(prefix string, num int) string { return fmt.Sprintf("%s-block%d.md", prefix, num) }

// plain is an unannotated target block (no backlink anywhere).
func plain(n int) string { return fmt.Sprintf("# Block %d\n\nOriginal claim.\n", n) }

// files builds a corpus map from name, body pairs.
func files(pairs ...string) map[string]string {
	m := map[string]string{}
	for i := 0; i < len(pairs); i += 2 {
		m[pairs[i]] = pairs[i+1]
	}
	return m
}

// runCorpus runs the command on a corpus and returns what a caller sees.
func runCorpus(t *testing.T, m map[string]string) observed {
	t.Helper()
	return runGo(corpus(t, m))
}

type rule struct {
	name  string
	files map[string]string
	code  int
	has   []string // regexes that must match the stdout
	not   []string // regexes that must not match the stdout
}

func runRules(t *testing.T, rules []rule) {
	t.Helper()
	for _, r := range rules {
		t.Run(r.name, func(t *testing.T) {
			o := runCorpus(t, r.files)
			if o.code != r.code {
				t.Errorf("exit %d, want %d\nstdout:\n%sstderr:\n%s", o.code, r.code, o.stdout, o.stderr)
			}
			for _, re := range r.has {
				if !regexp.MustCompile(re).MatchString(o.stdout) {
					t.Errorf("stdout lacks /%s/:\n%s", re, o.stdout)
				}
			}
			for _, re := range r.not {
				if regexp.MustCompile(re).MatchString(o.stdout) {
					t.Errorf("stdout has /%s/:\n%s", re, o.stdout)
				}
			}
		})
	}
}

const okLine = `(?m)^   ok     every declared correction has its reciprocal 'corrected in BN' backlink\.$`

func TestUsageAndDiscovery(t *testing.T) {
	if o := runGo(); o.code != 2 || o.stderr != "usage: verify-corrections.sh <target-dir>\n" || o.stdout != "" {
		t.Errorf("no argument: %+v", o)
	}
	if o := runGo(t.TempDir() + "/missing"); o.code != 2 || !strings.HasPrefix(o.stderr, "usage:") {
		t.Errorf("missing directory: %+v", o)
	}
	d := corpus(t, files("notes.md", "# not a block\n"))
	if o := runGo(d); o.code != 2 || o.stdout != "" || o.stderr != "verify-corrections: no block files under "+d+"\n" {
		t.Errorf("no block files: %+v", o)
	}
	// Extra arguments are ignored, as the script only read $1: on a corpus that SUCCEEDS the report is the same.
	ok := corpus(t, files("t-block1.md", plain(1), "t-block2.md", "> Corrects [Block 1].\n", "t-block3.md", plain(3)))
	base := runGo(ok)
	if base.code != 1 || !strings.Contains(base.stdout, "FAIL   B2 corrects [Block 1]") {
		t.Fatalf("the control corpus must produce a report: %+v", base)
	}
	if o := runGo(ok, "extra", "--more"); o != base {
		t.Errorf("extra arguments changed the run:\n%+v\nvs\n%+v", o, base)
	}
}

func TestBlockDiscovery(t *testing.T) {
	declares := "# B\n\n> Corrects [Block 99].\n"
	d := corpus(t, files(
		"a-block1.md", declares, // depth 1
		"x/a-block2.md", declares, // depth 2
		"x/y/a-block3.md", declares, // depth 3
		"x/y/z/a-block4.md", declares, // depth 4: out of reach
		"a-block5.template.md", declares, // template
		".git/a-block6.md", declares, // inside .git
		"x/.git/a-block7.md", declares,
		"block8.md", declares, // no prefix: not a block file
		"blocked-notes.md", declares,
	))
	o := runGo(d)
	if got := strings.Count(o.stdout, "declares a correction of [Block 99]"); got != 3 {
		t.Errorf("%d block files consulted, want 3 (depth <= 3, no template, no .git, canonical names only)\n%s", got, o.stdout)
	}
	for _, n := range []string{"B1 ", "B2 ", "B3 "} {
		if !strings.Contains(o.stdout, n+"declares") {
			t.Errorf("block %s not consulted:\n%s", n, o.stdout)
		}
	}
}

func TestReportOrderIsBytewise(t *testing.T) {
	m := files("b-block1.md", "# 1\n> Corrects [Block 9].\n", "B-block2.md", "# 2\n> Corrects [Block 9].\n", "a-block3.md", "# 3\n> Corrects [Block 9].\n")
	o := runCorpus(t, m)
	i2, i3, i1 := strings.Index(o.stdout, "B2 "), strings.Index(o.stdout, "B3 "), strings.Index(o.stdout, "B1 ")
	if !(i2 < i3 && i3 < i1) {
		t.Errorf("want B-block2 < a-block3 < b-block1 (byte order):\n%s", o.stdout)
	}
}

func TestReciprocalBacklink(t *testing.T) {
	runRules(t, []rule{
		{"1 reciprocated", files("t-block33.md", "# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n", "t-block8.md", "# Block 8\n\nClaim.\n\n> Note: corrected in B33.\n"),
			0, []string{okLine, `(?m)^== verify-corrections: [^ ]+ ==$`, `(?m)^== exit 0 ==$`}, []string{`FAIL`}},
		{"2 one-directional", files("t-block33.md", "# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n", "t-block8.md", "# Block 8\n\nNever annotated.\n"),
			1, []string{`(?m)^   FAIL   B33 corrects \[Block 8\] but t-block8\.md has no reciprocal backlink to B33 \(accepted: .*\) \(§14\) \[correcting: t-block33\.md\]$`, `(?m)^== exit 1 ==$`}, []string{okLine}},
		{"3 plain connection", files("t-block33.md", "# Block 33\n\n## Connections\n- **[Block 8]** — extends it.\n", "t-block8.md", plain(8)), 0, []string{okLine}, nil},
		{"4 adjective correct", files("t-block33.md", "# Block 33\n\nThe correct value is 5 V, matching [Block 8].\n", "t-block8.md", plain(8)), 0, []string{okLine}, nil},
		{"5 first ref only", files("t-block33.md", "# Block 33\n\n> Corrects [Block 8] §2; cf. [Block 12].\n", "t-block8.md", "# 8\n> corrected in B33.\n", "t-block12.md", plain(12)), 0, []string{okLine}, nil},
		{"6 no verb at all", files("t-block1.md", plain(1), "t-block2.md", plain(2)), 0, []string{okLine}, nil},
		{"7 self correction skipped", files("t-block3.md", "# 3\n\n> Corrects [Block 3] §3.1 (my own earlier paragraph).\n"), 0, []string{okLine}, []string{`AMBIG|FAIL|WARN`}},
		{"8 the target names another block", files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "CORRIGENDUM [Bloque 90]\n"), 1, []string{`FAIL +B82 corrects \[Block 21\]`}, nil},
		{"9 duplicate number written twice is one target", files("t-block33.md", "> Corrects [Block 8]. Later it corrects [Block 008] again.\n", "t-block8.md", plain(8)), 1,
			[]string{`(?m)^   FAIL   B33 corrects \[Block 8\] `}, []string{`(?s)FAIL.*FAIL`}},
	})
}

func TestClauseBinding(t *testing.T) {
	runRules(t, []rule{
		{"1 parenthetical postfix verb", files("t-block3.md", plain(3), "t-block9.md", plain(9), "t-block30.md", "# 30\n\n> Connects [Block 3] (the premise this corrects), see [Block 9].\n"),
			1, []string{`FAIL +B30 corrects \[Block 3\] `}, []string{`B30 corrects \[Block 9\]`}},
		{"2 verb at line end, ref on the next line", files("t-block8.md", plain(8), "t-block31.md", "# 31\n\n> This block Corrects\n> [Block 8] §2 on Docker.\n"),
			1, []string{`FAIL +B31 corrects \[Block 8\] `}, nil},
		{"3 bracket wrapped inside the reference", files("t-block50.md", plain(50), "t-block32.md", "# 32\n\n> and, in doing so, corrects [Block\n> 50] §50.4 framing.\n"),
			1, []string{`FAIL +B32 corrects \[Block 50\] `}, nil},
		{"4 bullets are separate units; last bullet without newline", files("t-block12.md", plain(12), "t-block14.md", plain(14), "t-block33.md", "# 33\n\n- Corrects the earlier claim\n- [Block 12] cross-reference only\n- also corrects [Block 14]"),
			1, []string{`FAIL +B33 corrects \[Block 14\] `}, []string{`B33 corrects \[Block 12\]`}},
		{"5 single-line file without newline", files("t-block8.md", plain(8), "t-block34.md", "> Corrects [Block 8]."), 1, []string{`FAIL +B34 corrects \[Block 8\] `}, nil},
		{"6 a blank line ends the unit", files("t-block8.md", plain(8), "t-block35.md", "# 35\n\nCorrects the earlier claim\n\n[Block 8] is only cross-referenced here\n"), 0, []string{okLine}, nil},
		{"7 a conjunction ends the clause", files("t-block5.md", plain(5), "t-block36.md", "# 36\n\n> CORRECTS the backlog statement of G4, and\n> independently corroborates [Block 5].\n"),
			0, []string{`(?m)^   note   1 correction verb\(s\) governed no bracketed \[Block N\] ref in their own clause`}, []string{`B36 corrects`}},
		{"8 the next sentence is not the target", files("t-block52.md", plain(52), "t-block37.md", "# 37\n\n- **[Block 53]** — both bounded it; this block\n  corrects that — it is in the jar we hold. The property read ([Block 52]) may also live here.\n"),
			0, []string{okLine}, nil},
		{"9 a middle dot ends the clause", files("t-block8.md", plain(8), "t-block40.md", "# 40\n\n> Corrects the earlier claim · [Block 8] is only cross-referenced here\n"), 0, nil, []string{`B40 corrects`}},
		{"10 a semicolon ends the clause", files("t-block8.md", plain(8), "t-block41.md", "> Corrects the claim; [Block 8] is cross-referenced.\n"), 0, nil, []string{`B41 corrects`}},
		{"11 a real sentence end still splits", files("t-block8.md", plain(8), "t-block41.md", "# 41\n\n> This corrects the framing. [Block 8] is only cross-referenced.\n"), 0, []string{okLine}, nil},
		{"12 a close paren ends the clause", files("t-block8.md", plain(8), "t-block42.md", "> (This corrects it) see [Block 8].\n"), 0, nil, []string{`B42 corrects \[Block 8\]`}},
	})
	for _, abbr := range []string{"cf.", "e.g.", "i.e.", "vs.", "Fig.", "p.", "pp.", "approx.", "aprox.", "pág.", "núm.", "Sec.", "x."} {
		t.Run("abbreviation "+abbr, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", plain(8), "t-block41.md", fmt.Sprintf("# 41\n\n> This corrects the %s framing in [Block 8].\n", abbr)))
			if !strings.Contains(o.stdout, "FAIL   B41 corrects [Block 8] ") {
				t.Errorf("%q ended the clause:\n%s", abbr, o.stdout)
			}
		})
	}
}

func TestLists(t *testing.T) {
	declared := func(o observed, from int, nums ...int) []string {
		var missing []string
		for _, n := range nums {
			if !strings.Contains(o.stdout, fmt.Sprintf("B%d corrects [Block %d] ", from, n)) {
				missing = append(missing, fmt.Sprint(n))
			}
		}
		return missing
	}
	cases := []struct {
		name   string
		body   string
		wants  []int
		unwant []int
	}{
		{"and", "> Corrects [Block 6] §6.3–6.4 and [Block 5] §5.4.\n", []int{6, 5}, nil},
		{"three and four elements", "> Corrects [Block 1] and [Block 2] and [Block 3] and [Block 4].\n", []int{1, 2, 3, 4}, nil},
		{"Spanish y", "> Corrige [Block 1] y [Bloque 2].\n", []int{1, 2}, nil},
		{"slash", "> Corrects [Block 1]/[Block 2]/[Block 3].\n", []int{1, 2, 3}, nil},
		{"spaced slash", "> Corrige [Block 1] / [Block 2].\n", []int{1, 2}, nil},
		{"prose ends the list", "> Corrects [Block 1] and independently notes [Block 2].\n", []int{1}, []int{2}},
		{"plus is not a joiner", "> Corrects [Block 1] + [Block 2].\n", []int{1}, []int{2}},
		{"a bare comma is not a joiner", "> Corrects [Block 1], [Block 2] is related.\n", []int{1}, []int{2}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := files("t-block99.md", "# 99\n\n"+c.body)
			for n := 1; n <= 6; n++ {
				m[blk("t", n)] = plain(n)
			}
			o := runCorpus(t, m)
			if miss := declared(o, 99, c.wants...); len(miss) > 0 {
				t.Errorf("not targets: %v\n%s", miss, o.stdout)
			}
			if got := declared(o, 99, c.unwant...); len(got) != len(c.unwant) {
				t.Errorf("wrongly targets %v\n%s", c.unwant, o.stdout)
			}
		})
	}
}

func TestNonAssertiveNegatedAndUnbound(t *testing.T) {
	for _, s := range []string{"Se corrige [Block 8] en la siguiente iteración.", "Si no se corrige [Block 8], el error persiste.", "El bloque anterior corrigió [Block 8] en su momento.", "Los autores corrigieron [Block 8] después."} {
		t.Run("skipped "+s, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", plain(8), "t-block70.md", "# 70\n\n> "+s+"\n"))
			if o.code != 0 || !strings.Contains(o.stdout, "   note   1 correction verb(s) in a non-assertive form (passive 'se corrige', conditional, or past tense) were skipped, not treated as declarations (#1835): B70\n") {
				t.Errorf("%+v", o)
			}
		})
	}
	for _, s := range []string{"Corrige [Block 8] §2.", "Este bloque corrige [Block 8] §2.", "Aquel pase corrige [Block 8]."} {
		t.Run("assertive "+s, func(t *testing.T) {
			if o := runCorpus(t, files("t-block8.md", plain(8), "t-block71.md", "> "+s+"\n")); !strings.Contains(o.stdout, "B71 corrects [Block 8] ") {
				t.Errorf("%s", o.stdout)
			}
		})
	}
	t.Run("upper-case past tense", func(t *testing.T) {
		o := runCorpus(t, files("t-block8.md", plain(8), "t-block93.md", "CORRIGIÓ [Bloque 8] hace tiempo.\n", "t-block94.md", "CORRIGIERON [Bloque 8] hace tiempo.\n"))
		if strings.Contains(o.stdout, "corrects") || !strings.Contains(o.stdout, "note   2 correction verb(s) in a non-assertive form") || !strings.Contains(o.stdout, ": B93, B94\n") {
			t.Errorf("%s", o.stdout)
		}
	})
	for _, s := range []string{"Corrects nothing in [Block 8].", "no corrige [Block 8]", "never corrects [Block 8]", "Corrects no claim in [Block 8].", "Corrige ninguna afirmación de [Block 8]"} {
		t.Run("negated "+s, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", plain(8), "t-block21.md", "# 21\n\n> "+s+"\n"))
			if o.code != 0 || strings.Contains(o.stdout, "corrects [Block 8]") ||
				!strings.Contains(o.stdout, "   note   1 correction verb(s) were negated ('corrects nothing in B21', 'no corrige') and declare nothing (#1874): B21\n") ||
				!strings.Contains(o.stdout, "ok-partial 1 declared correction(s) NOT checked (ambiguous/missing target: 0 AMBIG, 0 WARN; 1 negated)") {
				t.Errorf("%+v", o)
			}
		})
	}
	for _, s := range []string{"Corrects nothing but [Block 8].", "Corrects no longer-valid claims in [Block 8]."} {
		t.Run("not negated "+s, func(t *testing.T) {
			if o := runCorpus(t, files("t-block8.md", plain(8), "t-block21.md", "> "+s+"\n")); strings.Contains(o.stdout, "were negated") {
				t.Errorf("exception/aside read as a negation:\n%s", o.stdout)
			}
		})
	}
	for _, w := range []string{"correctsx [Block 8]", "corrigeñ [Block 8]", "ñcorrige [Block 8]", "corrigiéndose [Block 8]"} {
		t.Run("another word "+w, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", plain(8), "t-block72.md", "# 72\n\n> "+w+".\n"))
			if strings.Contains(o.stdout, "FAIL") || strings.Contains(o.stdout, "AMBIG") {
				t.Errorf("%s", o.stdout)
			}
		})
	}
	t.Run("a non-ASCII letter before se is part of the word", func(t *testing.T) {
		o := runCorpus(t, files("t-block8.md", plain(8), "t-block70.md", "# 70\n\n> El pa\xc3\xb1se corrige [Block 8] \xc2\xa72.\n"))
		if !strings.Contains(o.stdout, "FAIL   B70 corrects [Block 8] ") {
			t.Errorf("ñse read as the passive se:\n%s", o.stdout)
		}
	})
}

func TestVocabulary(t *testing.T) {
	notes := []string{"CORRIGENDUM [Bloque 82]", "Corrigenda: see B82", "Erratum (B82)", "Errata — Block 82", "Corregida en B82", "corregidos por Bloque 82", "corrected in B82", "corregido en B82",
		"Refined in B82 (scope only).", "Refinamiento (B82): el alcance cambia.", "§14 refinement (2026-09-27, [Block 82]): narrower.", "refinado en B82", "_corrected in B82_", "—corrected in B82", "“corregido en B82”",
		"corrected in b082", "corrected in Bloque  082", "CORRECCIÓN — [Block 82].", "**Correction (2026-01-01) — [Bloque 82] §4.1.**", "Correction [Block 82];"}
	for _, n := range notes {
		t.Run("accepts "+n, func(t *testing.T) {
			o := runCorpus(t, files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "# 21\n\nOriginal.\n\n> "+n+"\n"))
			if o.code != 0 {
				t.Errorf("not a backlink:\n%s", o.stdout)
			}
		})
	}
	rejected := []string{"Refinement planned, see B82.", "uncorrected in B82", "miscorrected in B82", "corrected in B820", "corrected in B8", "corrected in B82x", "corrected in xB82", "corrected in B1082",
		"Correction: [Block 82] was wrong", "miscorrection [Block 82].", "Correction [Block 82], and more", "CORRECCIÓN — [Block 82]: texto", "corrected in Block 83"}
	for _, n := range rejected {
		t.Run("rejects "+n, func(t *testing.T) {
			o := runCorpus(t, files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "# 21\n\nOriginal.\n\n> "+n+"\n"))
			if o.code != 1 {
				t.Errorf("read as a backlink:\n%s", o.stdout)
			}
		})
	}
	t.Run("the vocabulary line must name the block, the naming line must carry the vocabulary", func(t *testing.T) {
		o := runCorpus(t, files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "corrected in B5\nsee B82 for details\n"))
		if o.code != 1 {
			t.Errorf("two different lines satisfied one note:\n%s", o.stdout)
		}
	})
	t.Run("a note in a target that sits in another focus prefix does not count", func(t *testing.T) {
		o := runCorpus(t, files("aa-block4.md", "> Corrects [Block 1].\n", "aa-block1.md", plain(1), "zz-block1.md", "corrected in B4.\n"))
		if o.code != 1 || !strings.Contains(o.stdout, "but aa-block1.md has") {
			t.Errorf("%s", o.stdout)
		}
	})
}

func TestCorrigendum(t *testing.T) {
	declares := []string{"CORRIGENDUM `[CERT]` al [Bloque 8] §2.", "CORRIGENDUM al [Bloque 8].", "Corrigenda a [Block 8].", "CORRIGENDUM [CERT] to [Block 8].", "corrigendum of `[CERT]` [Block 8].",
		"CORRIGENDUM for [Block 8]: §8.2 overstated.", "CORRIGENDUM to the [Block 8]", "CORRIGENDUM to `[CERT]` [Block 8]", "Corrigenda of `[CERT]` [Bloque 8]."}
	for _, s := range declares {
		t.Run("declares "+s, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", plain(8), "t-block107.md", "# 107\n\n"+s+"\n"))
			if !strings.Contains(o.stdout, "FAIL   B107 corrects [Block 8] ") {
				t.Errorf("%s", o.stdout)
			}
		})
	}
	t.Run("two refs: the one after the preposition is the target", func(t *testing.T) {
		o := runCorpus(t, files("t-block32.md", plain(32), "t-block33.md", plain(33), "t-block92.md", "CORRIGENDUM [Bloque 33] al [Bloque 32].\n"))
		if !strings.Contains(o.stdout, "B92 corrects [Block 32] ") || strings.Contains(o.stdout, "B92 corrects [Block 33]") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("a block-ref tag before the preposition is not a declaration", func(t *testing.T) {
		o := runCorpus(t, files("t-block6.md", plain(6), "t-block90.md", "CORRIGENDUM `[Block 5]` al [Block 6].\n"))
		if strings.Contains(o.stdout, "FAIL") || !strings.Contains(o.stdout, "note   1 correction verb(s)") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("a bare noun before the ref is a backlink and declares nothing", func(t *testing.T) {
		o := runCorpus(t, files("t-block82.md", "> Corrects [Block 21].\n", "t-block21.md", "CORRIGENDUM [Bloque 82] — see there.\n"))
		if o.code != 0 || strings.Contains(o.stdout, "B21 corrects") || strings.Contains(o.stdout, "note   ") {
			t.Errorf("%s", o.stdout)
		}
	})
	for _, s := range []string{"Corrigendum (see [Block 33]).", "CORRIGENDUM: [Block 33] revises §8.2.", "CORRIGENDUM — [Bloque 33]", "Corrigendum: [Block 33] §2 was wrong.", "CORRIGENDUM (to [Block 33])"} {
		t.Run("noun form is surfaced, not a declaration: "+s, func(t *testing.T) {
			o := runCorpus(t, files("t-block8.md", "# 8\n\n> "+s+"\n", "t-block33.md", "> Corrects [Block 8].\n"))
			if o.code != 0 || strings.Contains(o.stdout, "FAIL") || !strings.Contains(o.stdout, "note   1 correction verb(s)") {
				t.Errorf("%+v", o)
			}
		})
	}
	t.Run("possessive of a block is a typed ambiguity", func(t *testing.T) {
		o := runCorpus(t, files("t-block33.md", plain(33), "t-block90.md", "See the corrigendum of [Block 33].\n"))
		if !strings.Contains(o.stdout, "AMBIG  B90 corrects [Block 33] — possessive 'corrigendum of [Block 33]': a reference to that block's corrigendum") || o.code != 0 {
			t.Errorf("%+v", o)
		}
	})
	t.Run("a ref-less corrigendum is counted in the unbound note", func(t *testing.T) {
		o := runCorpus(t, files("t-block8.md", plain(8), "t-block91.md", "The corrigendum table lists nothing yet.\n"))
		if !strings.Contains(o.stdout, "note   1 correction verb(s) governed no bracketed") {
			t.Errorf("%s", o.stdout)
		}
	})
}

func TestPrefixScope(t *testing.T) {
	for _, own := range []string{"aa", "zz"} {
		other := map[string]string{"aa": "zz", "zz": "aa"}[own]
		t.Run("own prefix wins: "+own, func(t *testing.T) {
			o := runCorpus(t, files(blk(own, 4), "# 4\n\n> Corrects [Block 1] §1.2.\n", blk(own, 1), "# 1\n\n> corrected in B4.\n", blk(other, 1), plain(1)))
			if o.code != 0 {
				t.Errorf("checked the colliding %s-block1:\n%s", other, o.stdout)
			}
		})
	}
	t.Run("a real gap in the own prefix fails and names it", func(t *testing.T) {
		o := runCorpus(t, files(blk("aa", 4), "> Corrects [Block 1].\n", blk("aa", 1), plain(1), blk("zz", 1), "corrected in B4.\n"))
		if o.code != 1 || !strings.Contains(o.stdout, "FAIL   B4 corrects [Block 1] but aa-block1.md ") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("one other prefix has it: unique fallback", func(t *testing.T) {
		o := runCorpus(t, files(blk("aa", 4), "> Corrects [Block 9].\n", blk("zz", 9), plain(9)))
		if o.code != 1 || !strings.Contains(o.stdout, "but zz-block9.md ") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("several other prefixes: ambiguous warning, not guessed", func(t *testing.T) {
		o := runCorpus(t, files(blk("cc", 4), "> Corrects [Block 1].\n", blk("aa", 1), plain(1), blk("zz", 1), plain(1)))
		if o.code != 0 || !strings.Contains(o.stdout, "   WARN   B4 declares a correction of [Block 1] but no block-1 file exists in its prefix 'cc' and the number is ambiguous across 2 other prefixes; NOT checked\n") ||
			!strings.Contains(o.stdout, "ok-partial 1 declared correction(s) NOT checked (ambiguous/missing target: 0 AMBIG, 1 WARN; 0 negated)") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("missing target", func(t *testing.T) {
		o := runCorpus(t, files("t-block33.md", "> Corrects [Block 99].\n"))
		if o.code != 0 || !strings.Contains(o.stdout, "   WARN   B33 declares a correction of [Block 99] but no block-99 file exists on disk\n") || strings.Contains(o.stdout, "ok     every") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("zero padded names resolve to the same number", func(t *testing.T) {
		o := runCorpus(t, files("t-block033.md", "> Corrects [Block 8].\n", "t-bloque008.md", "corrected in B33\n"))
		if o.code != 0 || !strings.Contains(o.stdout, "ok     every") {
			t.Errorf("%s", o.stdout)
		}
	})
	t.Run("the last block<N> of a name is the number", func(t *testing.T) {
		for in, want := range map[string][2]string{"fluke-block21.md": {"fluke", "21"}, "a-block1-block2.md": {"a-block1", "2"}, "x-bloque007-slug.md": {"x", "7"}, "x-block000.md": {"x", "0"}, "pi5-decoding-block8.md": {"pi5-decoding", "8"}} {
			if p, n := blockKey(in); p != want[0] || n != want[1] {
				t.Errorf("blockKey(%q) = %q, %q; want %q, %q", in, p, n, want[0], want[1])
			}
		}
	})
}

func TestQualifiers(t *testing.T) {
	runRules(t, []rule{
		{"1 qualifier names an existing prefix", files(blk("aa", 4), "> Corrects `zz` [Block 1] §1.2.\n", blk("aa", 1), "corrected in B4.\n", blk("zz", 1), plain(1)), 1, []string{`but zz-block1\.md `}, nil},
		{"2 after-ref form", files(blk("aa", 4), "> Corrects [Block 1] of the `zz` focus.\n", blk("aa", 1), plain(1), blk("zz", 1), "corrected in B4.\n"), 0, []string{okLine}, nil},
		{"3 unresolvable hard qualifier", files(blk("aa", 4), "> Corrects [Block 1] of the `ghost` focus.\n", blk("aa", 1), plain(1), blk("zz", 1), plain(1)), 0,
			[]string{"(?m)^   AMBIG  B4 corrects \\[Block 1\\] — cross-focus qualifier `ghost` names no focus prefix \\(no block file carries it, no FOCUSES.md row maps it\\); target NOT guessed; NOT checked", `ok-partial 1 `}, []string{`FAIL`}},
		{"4 qualifier = own prefix", files(blk("aa", 4), "> Corrects `aa` [Block 1].\n", blk("aa", 1), plain(1), blk("zz", 1), plain(1)), 1, []string{`but aa-block1\.md `}, nil},
		{"5 resolved through FOCUSES.md", files(blk("pi5", 8), "> Corrects `integration` [Block 5].\n", blk("pi5", 5), plain(5), blk("hb", 5), "corrected in B8\n",
			"FOCUSES.md", "| Focus | S | State | Block prefix | Q |\n|---|---|---|---|---|\n| `integration` | x | y | `hb-blockN.md` | q |\n"), 0, []string{okLine}, nil},
		{"6 tab padded slug cell", files(blk("pi5", 8), "> Corrects `integration` [Block 5].\n", blk("pi5", 5), plain(5), blk("hb", 5), plain(5),
			"FOCUSES.md", "| Focus | S | State | Block prefix | Q |\n|---|---|---|---|---|\n|\t`integration`\t| x | y | `hb-blockN.md` | q |\n"), 1, []string{`but hb-block5\.md `}, nil},
		{"7 same number in another focus is not a self correction", files(blk("aa", 3), "> Corrects `zz` [Block 3] §3.1.\n", blk("zz", 3), plain(3)), 1, []string{`but zz-block3\.md `}, nil},
		{"8 soft slug naming no focus falls back with a hint", files(blk("t", 90), "> Corrects [Block 8] in `parser.c`.\n", blk("t", 8), plain(8)), 1,
			[]string{"hint: the backticked token `parser.c` named no focus"}, []string{`AMBIG`}},
		{"9 lead slug naming no focus falls back", files(blk("t", 90), "> Corrects `foo` [Block 8].\n", blk("t", 8), plain(8)), 1, []string{"hint: the backticked token `foo` named no focus"}, nil},
		{"10 soft slug naming a prefix qualifies", files(blk("aa", 4), "> Corrects [Block 1] in `zz`.\n", blk("aa", 1), "corrected in B4.\n", blk("zz", 1), plain(1)), 1, []string{`but zz-block1\.md `}, []string{`hint`}},
		{"11 the list inherits the qualifier", files(blk("aa", 4), "> Corrects `zz` [Block 1] and [Block 2] and [Block 3].\n", blk("aa", 1), "corrected in B4.\n", blk("aa", 2), "corrected in B4.\n", blk("aa", 3), "corrected in B4.\n",
			blk("zz", 1), plain(1), blk("zz", 2), plain(2), blk("zz", 3), plain(3)), 1, []string{`but zz-block1\.md `, `but zz-block2\.md `, `but zz-block3\.md `}, nil},
		{"12 qualifier after the last ref of a list", files(blk("aa", 4), "> Corrects [Block 1] and [Block 2] of the `zz` focus.\n", blk("aa", 1), "corrected in B4.\n", blk("aa", 2), "corrected in B4.\n", blk("zz", 1), plain(1), blk("zz", 2), plain(2)), 1,
			[]string{`but zz-block1\.md `, `but zz-block2\.md `}, nil},
		{"13 qualified target absent from its prefix", files(blk("aa", 4), "> Corrects `zz` [Block 9].\n", blk("zz", 1), plain(1)), 0,
			[]string{"(?m)^   WARN   B4 declares a correction of \\[Block 9\\] of focus `zz` but no block-9 file exists in its prefix 'zz'; NOT checked$"}, nil},
	})
	t.Run("a slug differing only by case resolves deterministically", func(t *testing.T) {
		for i := 0; i < 20; i++ {
			o := runCorpus(t, files(blk("aa", 4), "> Corrects `foo` [Block 1] of the `foo` focus.\n", blk("Foo", 1), plain(1), blk("FOO", 1), plain(1)))
			if !strings.Contains(o.stdout, "but FOO-block1.md ") {
				t.Fatalf("run %d: want the byte-smallest prefix FOO:\n%s", i, o.stdout)
			}
		}
	})
}

func TestAmbiguousClasses(t *testing.T) {
	runRules(t, []rule{
		{"1 locator", files("t-block16.md", plain(16), "t-block21.md", "- Corrects the claim introducida junto a [Block 16] (dashboard).\n"), 0, []string{`AMBIG  B21 corrects \[Block 16\] — locator reference`}, []string{`FAIL`}},
		{"2 locator control", files("t-block16.md", plain(16), "t-block21.md", "- Corrects the calendar claim introduced in [Block 16] (dashboard).\n"), 1, []string{`FAIL +B21 corrects \[Block 16\] `}, nil},
		{"3 reader assumption", files("t-block1.md", plain(1), "t-block139.md", "> This corrects the assumption behind [Block 1]'s naming for anyone reading.\n"), 0, []string{`AMBIG  B139 corrects \[Block 1\] — a reader-assumption correction`}, nil},
		{"4 assumption control", files("t-block1.md", plain(1), "t-block139.md", "> This corrects the assumption made in [Block 1] about the module names.\n"), 1, []string{`FAIL +B139 corrects \[Block 1\] `}, nil},
		{"5 possessive process noun", files("t-block1.md", plain(1), "t-block83.md", "> corrects this focus's bootstrap remittance — kitControl is DONE ([Block 537]/[Block 538]/[Block 545])\n", "t-block537.md", plain(537), "t-block538.md", plain(538), "t-block545.md", plain(545)), 0,
			[]string{`AMBIG  B83 corrects \[Block 537\] — the verb governs a non-block object`, `AMBIG  B83 corrects \[Block 538\] `, `AMBIG  B83 corrects \[Block 545\] `}, []string{`FAIL`}},
		{"6 possessive of a code artifact is a plain claim", files("t-block8.md", plain(8), "t-block91.md", "> Corrects the decompiler's reading in [Block 8].\n"), 1, []string{`FAIL +B91 corrects \[Block 8\] `}, []string{`AMBIG`}},
		{"7 gap label object (postfix)", files("t-block50.md", plain(50), "t-block74.md", "- [Block 50] (the review — corrects the caller's B50-G6 mislabel)\n"), 0, []string{`AMBIG  B74 corrects \[Block 50\] — the verb governs a non-block object`}, nil},
		{"8 joined list followed by a verb parenthetical", files("t-block50.md", plain(50), "t-block51.md", plain(51), "t-block60.md", "> [Block 50]/[Block 51] (corrige el alcance)\n"), 1,
			[]string{`FAIL +B60 corrects \[Block 50\] `, `AMBIG  B60 corrects \[Block 51\] — joined-list reference`}, nil},
		{"9 postfix control (premise this corrects)", files("t-block3.md", plain(3), "t-block30.md", "> Connects [Block 3] (the premise this corrects).\n"), 1, []string{`FAIL +B30 corrects \[Block 3\] `}, nil},
	})
}

func TestBareReferences(t *testing.T) {
	runRules(t, []rule{
		{"1 unreciprocated bare ref is advisory", files("t-block292.md", plain(292), "t-block5.md", "corrected in B300.\n", "t-block300.md", "> Corrects B292 §292.6 and B5 §5.1.\n"), 0,
			[]string{`(?m)^   AMBIG  B300 corrects \[Block 292\] — bare B292 reference with no reciprocal backlink in t-block292\.md \(advisory: a bare ref is checked, never refused\); NOT checked`}, []string{`FAIL`, `AMBIG +B300 corrects \[Block 5\]`}},
		{"2 bare ref leads the clause", files("t-block34.md", plain(34), "t-block38.md", "# 38\n\n# x — and §14 CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described\n"), 0,
			[]string{`AMBIG  B38 corrects \[Block 67\] — bare B67 reference, no block-67 file exists on disk \(advisory\)`}, []string{`B38 corrects \[Block 34\]`}},
		{"3 a bare ref to the block itself", files("t-block8.md", plain(8), "t-block67.md", "> CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described.\n"), 0, []string{okLine}, []string{`AMBIG`}},
		{"4 bare lists", files("t-block6.md", plain(6), "t-block12.md", plain(12), "t-block15.md", plain(15), "t-block20.md", plain(20), "t-block100.md", "> Corrects B6/B12 and B15.\n", "t-block101.md", "> Corrige B20 y B6.\n"), 0,
			[]string{`AMBIG  B100 corrects \[Block 6\] `, `AMBIG  B100 corrects \[Block 12\] `, `AMBIG  B100 corrects \[Block 15\] `, `AMBIG  B101 corrects \[Block 20\] `, `AMBIG  B101 corrects \[Block 6\] `}, []string{`FAIL`}},
		{"5 prose ends a bare list", files("t-block6.md", plain(6), "t-block7.md", plain(7), "t-block102.md", "> Corrects B6 (see also B7) here.\n"), 0, nil, []string{`B102 corrects \[Block 7\]`}},
		{"6 gap label is not a block ref", files("t-block9.md", plain(9), "t-block103.md", "> Corrects B50-G6 and B9.\n"), 0, nil, []string{`B103 corrects \[Block 50\]`}},
		{"7 a bracketed ref joined to a bare list is mixed", files("t-block6.md", plain(6), "t-block11.md", plain(11), "t-block7.md", "> Corrects B6 and [Block 11] §3.\n"), 0,
			[]string{`AMBIG  B7 corrects \[Block 11\] — bracketed \[Block 11\] joined to a leading bare B<N> list \(#1874\) with no reciprocal backlink in t-block11\.md \(advisory: a joined bracketed ref is checked, never refused\)`}, []string{`FAIL`}},
		{"8 bare ref ambiguous across prefixes", files("cc-block4.md", "> Corrects B1.\n", "aa-block1.md", plain(1), "zz-block1.md", plain(1)), 0, []string{`bare B1 reference, number ambiguous across 2 other prefixes \(advisory\)`}, []string{`(?m)^   WARN`}},
	})
}

func TestLegacyDefectsFixed(t *testing.T) {
	t.Run("D1 block numbers beyond 64 bits are compared as digits", func(t *testing.T) {
		huge := "99999999999999999999999999"
		o := runCorpus(t, files("t-block7.md", "> Corrects [Block "+huge+"].\n", "t-block"+huge+".md", plain(1)))
		if o.code != 1 || !strings.Contains(o.stdout, "FAIL   B7 corrects [Block "+huge+"] but t-block"+huge+".md ") || !strings.Contains(o.stdout, "== exit 1 ==") {
			t.Errorf("%+v", o)
		}
	})
	t.Run("D2 a NUL byte in a target does not hide its backlink", func(t *testing.T) {
		o := runCorpus(t, files("t-block33.md", "> Corrects [Block 8].\n", "t-block8.md", "claim\x00binary\ncorrected in B33\n"))
		if o.code != 0 {
			t.Errorf("%+v", o)
		}
	})
	t.Run("D3 zero padded duplicates are one finding", func(t *testing.T) {
		o := runCorpus(t, files("t-block1.md", plain(1), "t-block2.md", "> Corrects [Block 1], later [Block 001] again: corrects [Bloque 01].\n"))
		if got := strings.Count(o.stdout, "FAIL"); got != 1 {
			t.Errorf("%d findings:\n%s", got, o.stdout)
		}
	})
	t.Run("D4 an unreadable block file is a degraded exit 1 naming it", func(t *testing.T) {
		d := corpus(t, files("t-block1.md", plain(1), "t-block2.md", "> Corrects [Block 1].\n"))
		var out, errb strings.Builder
		s := stdio(&out, &errb)
		code := run([]string{d}, s, func(p string) ([]byte, error) {
			if strings.HasSuffix(p, "t-block2.md") {
				return nil, fmt.Errorf("permission denied")
			}
			return readFile(p)
		})
		if code != 1 || errb.String() != "verify-corrections: degraded: extractor (awk) failed on t-block2.md: permission denied; the corpus was NOT checked\n" || strings.Contains(out.String(), "== exit") || strings.Contains(out.String(), "ok ") {
			t.Errorf("code %d\nstdout:\n%sstderr:\n%s", code, out.String(), errb.String())
		}
	})
}
