package gaprows

import (
	"fmt"
	"math/rand"
	"strings"
)

// The case tables are shared by the differential test (default build: the frozen bash oracle) and the golden test
// (both builds: the recorded answers), so the two cannot drift apart.

type namedSrc struct{ name, src string }

type bulletCase struct{ name, src, id string }

type overlapCase struct{ name, row, bullet string }

// genCase is one seeded generated case: a state file, a block file, three ids to look up and a pair of word lists.
type genCase struct {
	name         string
	state, block string
	ids          [3]string
	row, bullet  string
}

// genSeeds are the seeds of the generated corpora; each is a fixed, independent stream.
var genSeeds = []int64{2645, 7, 31}

const genPerSeed = 60

func fixtureStates() []namedSrc {
	return []namedSrc{
		{"single", "| high | B1-G2 how it works | w | pending |\n"},
		{"three", tbl + "| high | B1-G1 first | w | pending |\n| low | B2-G1 middle | w | done |\n| medium | B3-G1 last | w | Pending review |"},
		{"escaped", "| high | B4-G1 a \\| b \\\\| c | w | pending |\n"},
		{"crlf", "| high | B5-G1 text | w | pending |\r\n| — | B5-G2 old | w | done |\r\n| high | B5-G3 x |\r\n"},
		{"closed", "| — | B1-G1 a | w | done |\n| ~~low~~ | B1-G2 b | w | done |\n| 7 | B1-G3 c | w | pending |\n| 7 | B1-G4 d | w | done |\n| — | B1-G5 e | pending |\n"},
		{"unparsed", "| urgent | B1-G1 x | w | pending |\n| high | B1-G2 x |\n| high | B1-G3 " + strings.Repeat("y", 120) + " | w | pending |\n"},
		{"unparsed cut at 90", "| high | B1-G1 " + strings.Repeat("y", 80) + "\n| high | B1-G2 " + strings.Repeat("y", 79) + "\n| high | B1-G3 " + strings.Repeat("y", 77) + "\n"},
		{"empty", ""},
		{"no-rows", "# title\nsome text\n"},
		{"tabs", "| high | B1-G1 a\tb | w | pending |\n"},
		{"indented", "   \t| high | B8-G1 x | w | pending |   \n"},
		{"bare pipes", "|\n||\n| |\n|||\n"},
		{"no final nl", "| high | B9-G1 x | w | pending |"},
		{"uppercase", "| high | B9-G1 x | w | PENDING |\n| high | B9-G2 x | w | Pend |\n"},
		{"status prefix lengths", "| high | B1-G1 x | w | pending |\n| high | B1-G2 x | w | pendin |\n| high | B1-G3 x | w | pendingg |\n| high | B1-G4 x | w | PeNdInG |\n| high | B1-G5 x | w | @ending |\n| high | B1-G6 x | w | `ending |\n| high | B1-G7 x | w | [ending |\n"},
		{"status fold edges", "| high | B1-G1 x | w | PENDING |\n| high | B1-G2 x | w | pendinG |\n| high | B1-G3 x | w | pending\n"},
		{"id forms", "| high | B9-G1x glued | w | pending |\n| high | B9-G | w | pending |\n| high | B-G1 x | w | pending |\n"},
		{"id without digits after G", "| high | B1-G x | w | pending |\n| high | B1-G\tx | w | pending |\n| high | B1-G | w | pending |\n"},
		{"empty cells", "| | B1-G1 x | | pending |\n| high | B1-G2 x | | |\n"},
		{"em-dash mid", "| a — b | B1-G1 x | w | pending |\n"},
		{"leading zero", "| high | B01-G002 x | w | pending |\n"},
		{"priorities", "| high | B1-G1 x | w | pending |\n| medium | B1-G2 x | w | pending |\n| low | B1-G3 x | w | pending |\n| deferred | B1-G4 x | w | pending |\n| High | B1-G5 x | w | pending |\n| 12 | B1-G6 x | w | pending |\n| 12a | B1-G7 x | w | pending |\n"},
	}
}

func fixtureBlocks() []namedSrc {
	return []namedSrc{
		{"forms", "- **B1-G1** a\n* **[B1-G2]** b\n- **B1-G3 (open, n)** c\n- **B1-G4**: d\n  - **B1-G5** nested\n- **B1-G10** ten\n"},
		{"cont", "- **B1-G1** first\nsecond\n  third\n1\n2\n3\n4\n5\n6\n7\n8\n\n- **B1-G2** after\n"},
		{"cont exactly seven", "- **B1-G1** first\n1\n2\n3\n4\n5\n6\n7\n- **B1-G2** after\n"},
		{"cont six then end", "- **B1-G1** first\n1\n2\n3\n4\n5\n6"},
		{"cont eight then end", "- **B1-G1** first\n1\n2\n3\n4\n5\n6\n7\n8"},
		{"stops", "- **B1-G1** x\n## H\n- **B1-G2** y\n- **B1-G3** z\nmore\n- **B1-G4** w\n \t \nzz\n"},
		{"crlf", "- **B1-G1** first\r\nmore\r\n"},
		{"twice", "- **B1-G1** one\n\n- **B1-G1** two\n"},
		{"nonl", "- **B1-G1** last"},
		{"prose", "see B1-G1 here\n**B1-G1** bare\n"},
		{"nothing", ""},
		{"bullet shapes", "- **B1-G1** dash\n* **B1-G2** star\n+ **B1-G3** plus\n-  **B1-G4** two spaces\n- *B1-G5* one star\n- **B1-G6\n- **\n- *\n-\n\t- **B1-G7** tab\n   * **[B1-G8]** bracket\n- **[B1-G9 closed\n"},
		{"short lines", "- **\n- **B\n- **B1\n- **B1-G\n- **B1-G1\n"},
	}
}

func bulletIDs() []string {
	return []string{"B1-G1", "B1-G2", "B1-G3", "B1-G4", "B1-G5", "B1-G6", "B1-G7", "B1-G8", "B1-G9", "B1-G10"}
}

func fixtureBulletCases() []bulletCase {
	var out []bulletCase
	for _, b := range fixtureBlocks() {
		for _, id := range bulletIDs() {
			out = append(out, bulletCase{b.name, b.src, id})
		}
	}
	return out
}

func fixtureOverlapCases() []overlapCase {
	var out []overlapCase
	for i, c := range [][2]string{
		{"widgets frobnicate sprockets", "- **B1-G1** widgets frobnicate sprockets"},
		{"cats and dogs", "widgets"}, {"the of an", "the of an"}, {"months", "month"}, {"class", "clas"},
		{"bosses", "boss"}, {"Widgets WIDGET", "widget"}, {"9.5.0 1166 v2", "9.5.0 1166 v2"}, {"a.b_c x.y", "a.b_c"},
		{"a b c d", "a b c d"}, {"", "x"}, {"naïve café", "naive cafe"}, {"foo-bar baz_qux", "foo bar baz_qux"},
		{`back\slash and "quotes"`, `back\slash`}, {"-e -n", "-e"}, {"price: 3.5 USDs", "usd"}, {"tokens.", "token."},
		// every end of every character class
		{"zebra zzz Zulu ZZZ", "zebra zzz zulu"}, {"abc ABC Abc aBC", "abc"}, {"axe Axe aXE AXE", "axe"},
		{"ab0 ab9 ab_ ab. ab/ ab: ab@ ab[", "ab0 ab9 ab_ ab."}, {"x9z a0b", "x9z a0b"}, {"09ab 0abc", "abc ab"},
		{"`abc@ [abc{ {abc [xyz`", "abc xyz"}, {"hello_world.foo_", "hello_world.foo_"}, {"é€ünicode", "nicode"},
		{"aa bb cc dd ee", "aa bb"}, {"abc abcs abcss abss ab", "abc abss"}, {"ass bss ds", "as"},
		{"Axe", "axe"}, {"bAt", "bat"}, {"ZZ", "zz"}, {"a", "a"}, {"ab", "ab"}, {"abc", "abc"}, {"abs", "ab"}, {"Q.x", "q.x"}, {"A. B. C.", "a."},
	} {
		out = append(out, overlapCase{fmt.Sprintf("fixture-%d", i), c[0], c[1]})
	}
	return out
}

var genWords = []string{"widgets", "widget", "frobnicate", "sprocket", "the", "of", "Q.x", "a", "b1", "ab", "class", "bosses", "9.5", "1166",
	"foo_bar", "x.y.z", "naïve", "über", "months", "month", "pending", "—", "~~", "\\|", "`code`", "B1-G1", "B1-G2",
	"Zebra", "ZZZ", "zz9", "Alpha", "ab0", "ab9", "xyz.", "a_b"}

func genText(r *rand.Rand, n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		if i > 0 {
			b.WriteString([]string{" ", " ", "\t", "  "}[r.Intn(4)])
		}
		b.WriteString(genWords[r.Intn(len(genWords))])
	}
	return b.String()
}

func genStateLine(r *rand.Rand) string {
	prios := []string{"high", "medium", "low", "deferred", "—", "~~low~~", "12", "urgent", "", "High"}
	stats := []string{"pending", "Pending: wait", "done", "closed", "", "pend", "PENDING", "pendin", "Pending"}
	id := fmt.Sprintf("B%d-G%d", r.Intn(4), r.Intn(4))
	switch r.Intn(12) {
	case 0:
		return genText(r, 3)
	case 1:
		return "| high | " + id + " " + genText(r, 3) + " |"
	case 2:
		return "|---|---|---|---|"
	case 3:
		return "  | " + prios[r.Intn(len(prios))] + " | " + id + " | x | " + stats[r.Intn(len(stats))] + " |  "
	}
	line := "| " + prios[r.Intn(len(prios))] + " | " + id + " " + genText(r, r.Intn(6)) + " | " + genText(r, 1) + " | " + stats[r.Intn(len(stats))] + " |"
	if r.Intn(5) == 0 {
		line += "\r"
	}
	return line
}

func genBlockLine(r *rand.Rand) string {
	id := fmt.Sprintf("B%d-G%d", r.Intn(3), r.Intn(12))
	switch r.Intn(9) {
	case 0:
		return ""
	case 1:
		return "## " + genText(r, 2)
	case 2:
		return "- **[" + id + "]** " + genText(r, 4)
	case 3:
		return "* **" + id + " (open)** " + genText(r, 4)
	case 4:
		return "  " + genText(r, 5)
	case 5:
		return "- **" + id + "**: " + genText(r, 4) + "\r"
	}
	return "- **" + id + "** " + genText(r, r.Intn(6))
}

// genCorpus is the seeded generated corpus: genPerSeed cases per seed, always the same bytes for a seed.
func genCorpus() []genCase {
	var out []genCase
	for _, seed := range genSeeds {
		r := rand.New(rand.NewSource(seed))
		for i := 0; i < genPerSeed; i++ {
			var s, b strings.Builder
			for l, n := 0, r.Intn(14); l < n; l++ {
				s.WriteString(genStateLine(r) + "\n")
			}
			for l, n := 0, r.Intn(16); l < n; l++ {
				b.WriteString(genBlockLine(r) + "\n")
			}
			c := genCase{name: fmt.Sprintf("gen-%d-%d", seed, i), state: s.String(), block: b.String()}
			if r.Intn(4) == 0 {
				c.state = strings.TrimSuffix(c.state, "\n")
			}
			for g := range c.ids {
				c.ids[g] = fmt.Sprintf("B%d-G%d", r.Intn(3), r.Intn(12))
			}
			c.row, c.bullet = genText(r, r.Intn(8)), genText(r, r.Intn(10))
			out = append(out, c)
		}
	}
	return out
}
