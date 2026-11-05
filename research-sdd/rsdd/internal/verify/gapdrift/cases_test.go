package gapdrift

import (
	"fmt"
	"math/rand"
	"strings"
)

// The case tables are shared by the differential test (default build: the frozen bash script) and the golden test
// (both builds: the recorded answers), so the two cannot drift apart.

const bullets1 = "# Block 1\n\n## Child gaps\n- **B1-G1** widgets frobnicate sprockets under load\n- **B1-G2** how does the gizmo calibrate\n- **B1-G3** alpha beta gamma delta epsilon\n- **B1-G10** unrelated ten\n"

// runCase is one command run on a corpus: files (relative path -> content) and the arguments, {D} standing for the
// corpus directory.
type runCase struct {
	name  string
	files map[string]string
	args  []string
}

// outcomeCases are the hand-written cases: every report line, every summary field, every option and every operational
// failure of the command.
func outcomeCases() []runCase {
	lorem := strings.Repeat("lorem ipsum dolor ", 8)
	cases := []runCase{
		{"clean: every row matches", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate sprockets under load", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"single row drift", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats and dogs and birds", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"drift at first, middle and last", map[string]string{"RESEARCH-STATE.md": state(
			row("high", "B1-G1 cats dogs birds", "pending"), row("low", "B1-G2 how does the gizmo calibrate", "pending"),
			row("medium", "B1-G3 alpha beta gamma delta epsilon", "pending"), row("high", "B1-G3 zebra yak xylophone walrus", "pending"),
			row("high", "B1-G2 fish frogs newts", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"threshold 0 flags nothing", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "0"}},
		{"threshold 100 flags a partial overlap", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "100"}},
		{"threshold boundary 67 (2 of 3 shared = 66%)", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "67"}},
		{"threshold boundary 66", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "66"}},
		{"non-pending skipped by default", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done"), row("low", "B1-G2 how does the gizmo calibrate", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"--all checks non-pending rows", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done"), row("low", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--all"}},
		{"--state names another file", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate sprockets", "pending")), "other.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/other.md"}},
		{"--state relative to cwd", map[string]string{"RESEARCH-STATE.md": "", "other.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{".", "--state", "other.md"}},
		{"relative target", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"."}},
		{"options in any order", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done")), "t-block1.md": bullets1}, []string{"{D}", "--all", "--threshold", "50", "--state", "{D}/RESEARCH-STATE.md"}},
		{"repeated --state keeps the last", map[string]string{"RESEARCH-STATE.md": "", "a.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "b.md": state(row("high", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/a.md", "--state", "{D}/b.md"}},
		{"CRLF state and block", map[string]string{"RESEARCH-STATE.md": strings.ReplaceAll(state(row("high", "B1-G1 cats dogs birds", "pending"), row("high", "B1-G2 how does the gizmo calibrate", "pending")), "\n", "\r\n"), "t-block1.md": strings.ReplaceAll(bullets1, "\n", "\r\n")}, []string{"{D}"}},
		{"escaped pipes in the row", map[string]string{"RESEARCH-STATE.md": state(row("high", `B1-G1 widgets \| frobnicate sprockets under \| load`, "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"long row text is cut at 90 characters", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 "+lorem+lorem, "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"non-ASCII text at the cut", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 "+strings.Repeat("ñandú café ", 12), "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-BULLET", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G9 some prose-only gap", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-BLOCK", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 gap in an absent block", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-WORDS", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 9.5.0 1166", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"UNPARSED", map[string]string{"RESEARCH-STATE.md": state(row("urgent", "B1-G1 x", "pending"), "| high | B1-G2 only three cells |"), "t-block1.md": bullets1}, []string{"{D}"}},
		{"closed-class rows are skipped", map[string]string{"RESEARCH-STATE.md": state(row("—", "B1-G1 closed", "done"), row("~~low~~", "B1-G2 struck", "done"), row("4", "B1-G3 history", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"only closed-class rows: not applicable", map[string]string{"RESEARCH-STATE.md": state(row("—", "B1-G1 closed", "done")), "t-block1.md": bullets1}, []string{"{D}", "--all"}},
		{"pending row with a numeric priority is compared", map[string]string{"RESEARCH-STATE.md": state(row("3", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"DEGRADED: rows in scope, none comparable", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 a", "pending"), row("high", "B1-G9 b", "pending"), row("high", "B1-G1 9.5.0", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"no backlog rows: not applicable", map[string]string{"RESEARCH-STATE.md": "# s\n\nno gap table\n", "t-block1.md": bullets1}, []string{"{D}"}},
		{"empty state file", map[string]string{"RESEARCH-STATE.md": "", "t-block1.md": bullets1}, []string{"{D}"}},
		{"no pending rows", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 x", "done"), row("low", "B1-G2 y", "closed")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"no block files at all", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"))}, []string{"{D}"}},
		{"B1-G1 never reads the B1-G10 bullet", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 unrelated ten", "pending")), "t-block1.md": "- **B1-G10** unrelated ten\n"}, []string{"{D}"}},
		{"bloque files and a suffix", map[string]string{"RESEARCH-STATE.md": state(row("high", "B2-G1 cats dogs birds", "pending")), "x-bloque2-notes.md": "- **B2-G1** cats dogs birds\n"}, []string{"{D}"}},
		{"block files three levels deep, not four", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"), row("high", "B2-G1 widgets", "pending")), "a/b/t-block1.md": bullets1, "a/b/c/t-block2.md": bullets1}, []string{"{D}"}},
		{".git and template files are ignored", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"), row("high", "B2-G1 widgets", "pending")), ".git/t-block1.md": bullets1, "t-block2.template.md": bullets1}, []string{"{D}"}},
		{"nested worktrees are ignored", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), ".claude/worktrees/w/t-block1.md": bullets1}, []string{"{D}"}},
		{"the first block file with the bullet wins", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate", "pending")), "a-block1.md": "# no bullet here\n", "b-block1.md": bullets1}, []string{"{D}"}},
		{"bullet forms", map[string]string{"RESEARCH-STATE.md": state(row("high", "B3-G1 aaa bbb ccc", "pending"), row("high", "B3-G2 aaa bbb ccc", "pending"), row("high", "B3-G3 aaa bbb ccc", "pending"), row("high", "B3-G4 aaa bbb ccc", "pending")),
			"t-block3.md": "- **[B3-G1]** aaa bbb ccc\n* **B3-G2 (open, note)** aaa bbb ccc\n- **B3-G3**: aaa bbb ccc\n  - **B3-G4** aaa\ncontinued bbb ccc\n"}, []string{"{D}"}},
		{"state with a different name in a subdir", map[string]string{"sub/STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/sub/STATE.md"}},
		// operational failures
		{"usage: no arguments", nil, []string{}},
		{"usage: empty target", nil, []string{""}},
		{"usage: target is not a directory", map[string]string{"f": "x"}, []string{"{D}/f"}},
		{"usage: missing directory", nil, []string{"{D}/nope"}},
		{"usage: unknown option", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--bogus"}},
		{"usage: --state without a value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state"}},
		{"usage: --state with an empty value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state", ""}},
		{"usage: --threshold without a value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold"}},
		{"usage: a stray positional argument", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "extra"}},
		{"threshold: not a number", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "abc"}},
		{"threshold: empty", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", ""}},
		{"threshold: negative", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "-5"}},
		{"threshold: decimal point", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "1.5"}},
		{"threshold: over 100", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "101"}},
		{"threshold: out of integer range", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "99999999999999999999999"}},
		{"threshold is checked before the state file", nil, []string{"{D}", "--threshold", "x"}},
		{"state file absent", map[string]string{"t-block1.md": bullets1}, []string{"{D}"}},
		{"state file is a directory", map[string]string{"RESEARCH-STATE.md/": ""}, []string{"{D}"}},
		{"--state names a missing file", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state", "{D}/missing.md"}},
		// shapes added with the recorded goldens: each pins a boundary the table above leaves implicit
		{"DEGRADED counts only the rows in scope", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 a", "pending"), row("high", "B1-G9 b", "pending"), row("high", "B1-G1 9.5.0", "pending"), row("low", "B7-G2 c", "done"), row("low", "B7-G3 d", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"DEGRADED with --all has no skipped rows", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 a", "pending"), row("low", "B7-G2 c", "done")), "t-block1.md": bullets1}, []string{"{D}", "--all"}},
		{"suspects only: exit 1 with no unparsed row", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"unparsed only: exit 1 with no suspect", map[string]string{"RESEARCH-STATE.md": state(row("urgent", "B1-G1 widgets frobnicate", "pending"), row("high", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"neither suspect nor unparsed: exit 0", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"one skipped closed row of each kind", map[string]string{"RESEARCH-STATE.md": state(row("—", "B1-G1 closed", "done"), row("high", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"every counter at once", map[string]string{"RESEARCH-STATE.md": state(
			row("—", "B1-G1 closed", "done"), row("urgent", "B1-G2 x", "pending"), row("high", "B7-G1 gap in an absent block", "pending"), row("high", "B1-G9 prose only", "pending"),
			row("high", "B1-G1 9.5.0", "pending"), row("high", "B1-G3 zebra yak xylophone", "pending"), row("high", "B1-G2 how does the gizmo calibrate", "pending"), row("low", "B1-G2 done one", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"overlap percent: 1 of 6 words", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets cats dogs birds frogs newts", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"overlap percent: 1 of 3 words at threshold 34", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets cats dogs", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "34"}},
		{"overlap percent: 1 of 3 words at threshold 33", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets cats dogs", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "33"}},
		{"row text of exactly 90 characters", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats "+strings.Repeat("d", 84), "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"row text of 91 characters", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats "+strings.Repeat("d", 85), "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"row text shorter than the cut", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"row text with an invalid byte", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats \xff\xfe dogs "+strings.Repeat("\xff", 100), "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"threshold 101 is refused, 100 is accepted", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "100"}},
		{"threshold 1000 is refused", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "1000"}},
		{"block files exactly three levels deep", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "a/b/t-block1.md": bullets1}, []string{"{D}"}},
		{"block files four levels deep are not listed", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "a/b/c/t-block1.md": bullets1}, []string{"{D}"}},
		{"block files two levels deep", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "a/t-block1.md": bullets1}, []string{"{D}"}},
		{"a deep directory next to a shallow block file", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"), row("high", "B2-G1 widgets", "pending")), "a/b/c/d/t-block2.md": bullets1, "t-block1.md": bullets1}, []string{"{D}"}},
		{"a target named .git lists nothing", map[string]string{".git/RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), ".git/t-block1.md": bullets1}, []string{"{D}/.git"}},
		{"a target named .git with a trailing slash", map[string]string{".git/RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), ".git/t-block1.md": bullets1}, []string{"{D}/.git/"}},
		{"a target whose name merely ends in .git", map[string]string{"x.git/RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "x.git/t-block1.md": bullets1}, []string{"{D}/x.git"}},
		{"relative target and relative state in a subdirectory", map[string]string{"sub/RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "sub/t-block1.md": bullets1}, []string{"sub"}},
		{"absolute state, relative target", map[string]string{"RESEARCH-STATE.md": "", "sub/s.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{".", "--state", "{D}/sub/s.md"}},
		{"target with a trailing slash", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}/"}},
		{"two block files, only the later one has the bullet", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G2 how does the gizmo calibrate", "pending")), "a-block1.md": "- **B1-G1** other\n", "b-block1.md": bullets1}, []string{"{D}"}},
	}
	return cases
}

var gdWords = strings.Fields("widgets frobnicate sprockets gizmo calibrate alpha beta gamma delta load month months class bosses 9.5.0 the of café ñandú x.y a")

func gdText(r *rand.Rand, n int) string {
	w := make([]string, n)
	for i := range w {
		w[i] = gdWords[r.Intn(len(gdWords))]
	}
	return strings.Join(w, " ")
}

// genSeeds are the seeds of the generated corpora; each is a fixed, independent stream.
var genSeeds = []int64{2645, 11, 23}

const genPerSeed = 40

// generatedCases are seeded random corpora: several block files, a state with random rows, thresholds and the --all
// flag. The seeds are fixed so a failure reproduces.
func generatedCases() []runCase {
	prios := []string{"high", "medium", "low", "deferred", "—", "urgent", "7"}
	stats := []string{"pending", "pending", "Pending (wait)", "done", "closed"}
	var out []runCase
	for _, seed := range genSeeds {
		r := rand.New(rand.NewSource(seed))
		for i := 0; i < genPerSeed; i++ {
			files := map[string]string{}
			for b := 1; b <= 3; b++ {
				if r.Intn(6) == 0 {
					continue // a block with no file
				}
				var sb strings.Builder
				for g := 1; g <= 6; g++ {
					if r.Intn(5) == 0 {
						continue
					}
					fmt.Fprintf(&sb, "- **B%d-G%d** %s\n", b, g, gdText(r, 2+r.Intn(5)))
					if r.Intn(3) == 0 {
						fmt.Fprintf(&sb, "%s\n", gdText(r, 3))
					}
				}
				name := fmt.Sprintf("t-block%d.md", b)
				if r.Intn(4) == 0 {
					name = fmt.Sprintf("sub/t-bloque%d-extra.md", b)
				}
				files[name] = sb.String()
			}
			var rows []string
			for n := r.Intn(8); n > 0; n-- {
				rows = append(rows, row(prios[r.Intn(len(prios))], fmt.Sprintf("B%d-G%d %s", 1+r.Intn(4), 1+r.Intn(7), gdText(r, r.Intn(6))), stats[r.Intn(len(stats))]))
			}
			files["RESEARCH-STATE.md"] = state(rows...)
			args := []string{"{D}", "--threshold", fmt.Sprint(r.Intn(101))}
			if r.Intn(2) == 0 {
				args = append(args, "--all")
			}
			out = append(out, runCase{fmt.Sprintf("generated-%d-%d", seed, i), files, args})
		}
	}
	return out
}
