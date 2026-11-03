package show

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const goldenIsBlocked = "testdata/golden/is-blocked.golden"

// blockedScenario is one state file and the gaps asked about it (each call is one is_blocked invocation).
type blockedScenario struct {
	name  string
	state string
	gaps  []string
}

// unreadable marks the one scenario whose state file is mode 000.
func (bs blockedScenario) unreadable() bool { return bs.name == "unreadable-state" }

func blockedScenarios() []blockedScenario {
	gaps := func(g ...string) []string { return g }
	return []blockedScenario{
		{"standard-bullets", "# S\n## Blocked gaps\n- G1 — needs: hardware\n- G2 - needs: a camera\n- G3 needs: x\n- G4\n- **G5** — NEEDS: Y\n- G6 — needs: x — needs: y\n  - nested — needs: z\n-G7 needs: no space\n- — needs: empty name\n## Gap-backlog\n- G8 — needs: elsewhere\n",
			gaps("G1", "G2", "G3", "G4", "**G5**", "G5", "G6", "G6 — needs: x", "nested", "G7", "G8", "hardware", "", "G 1")},
		{"three-sections-in-order", "## Non-investigable gaps\n- A1 — needs: x\n## Blocked / spyder\n- A2 — needs: y\n## Blocked gaps (legacy)\n- A3 — needs: z\n## Blocked gaps\n- A4\n## Blocked gaps\n- A5\n## Blockedgaps\n- A6\n  ## Blocked gaps\n- A7\n",
			gaps("A1", "A2", "A3", "A4", "A5", "A6", "A7")},
		{"no-blocked-section", "# S\n## Gap-backlog\n- G1 — needs: x\n", gaps("G1", "")},
		{"section-without-bullets", "## Blocked gaps\nprose only\n\n", gaps("G1", "prose only", "")},
		{"crlf-endings", "## Blocked gaps\r\n- G1 — needs: x\r\n- G2\r\n", gaps("G1", "G2", "G1\r")},
		{"no-trailing-newline", "## Blocked gaps\n- G1 — needs: x\n- G2", gaps("G1", "G2")},
		{"dash-variants", "## Blocked gaps\n- G1 – needs: x\n- G2 -- needs: y\n- G3 —— needs: z\n- G4-needs: w\n- G5 — - needs: v\n- G6 — x needs: u\n- G7 - — needs: t\n- Ñandú — needs: s\n- G9 -\n- G10 — needs:\n",
			gaps("G1", "G2", "G3", "G4", "G5", "G5 —", "G6", "G6 — x", "G7", "G7 -", "Ñandú", "G9", "G10")},
		{"child-gaps-not-names", "## Child gaps surfaced at close\n- G1 — needs: x\n## Blocked gaps\n- G2 — needs: y\n", gaps("G1", "G2")},
		{"tabs", "## Blocked gaps\n-\tG1\t— needs: x\n-\t\tG2\tneeds:\tx\n", gaps("G1", "G1\t", "G2")},
		{"indented-heading-is-not-a-section", "  ## Blocked gaps\n- G1 — needs: x\n", gaps("G1", "")},
		{"sub-heading-continues-the-section", "## Blocked gaps\n### detail\n- G1 — needs: x\n## Next\n- G2\n", gaps("G1", "G2")},
		{"empty-state", "", gaps("G1", "")},
		{"whitespace-lines-only", "## Blocked gaps\n   \n\t\n", gaps("G1", "")},
		{"empty-name-bullet", "## Blocked gaps\n- needs: x\n-\n- G1\n", gaps("G1", "", "needs:")},
		{"other-bullet-markers", "## Blocked gaps\n* G1 — needs: x\n1. G2 — needs: y\n+ G3\n- G4\n", gaps("G1", "G2", "G3", "G4", "* G1")},
		{"names-are-matched-exactly", "## Blocked gaps\n- hardware — needs: a board\n", gaps("hardware", "hard", "hardware board", "a board")},
		{"leading-and-trailing-blanks", "## Blocked gaps\n   -   G1   —   needs: x   \n- G2   \n", gaps("G1", "G2", "G1   ")},
		{"unreadable-state", "## Blocked gaps\n- G1\n", gaps("G1", "")},
	}
}

func (bs blockedScenario) build(t testing.TB) string {
	t.Helper()
	root := t.TempDir()
	p := filepath.Join(root, "RESEARCH-STATE.md")
	must(t, os.WriteFile(p, []byte(bs.state), 0o644))
	if bs.unreadable() {
		must(t, os.Chmod(p, 0))
	}
	return root
}

func runBlockedGo(t testing.TB, bs blockedScenario, root string) outcome {
	t.Helper()
	var out, errb bytes.Buffer
	c := &ctx{s: cli.Stdio{Out: &out, Err: &errb}, state: filepath.Join(root, "RESEARCH-STATE.md")}
	for i, g := range bs.gaps {
		fmt.Fprintf(&out, "gap%d -> %d\n", i, c.isBlocked(g))
	}
	return outcome{0, out.String(), errb.String()}
}

func TestReplayIsBlocked(t *testing.T) {
	golden := parseGolden(t, goldenIsBlocked)
	scs := blockedScenarios()
	if len(golden) != len(scs) {
		t.Fatalf("golden has %d scenarios, the table %d", len(golden), len(scs))
	}
	for _, bs := range scs {
		t.Run(bs.name, func(t *testing.T) {
			if bs.unreadable() && os.Geteuid() == 0 {
				t.Skip("mode-000 files are readable by root")
			}
			root := bs.build(t)
			got := render(bs.name, runBlockedGo(t, bs, root), root)
			if want := golden[bs.name]; got != want {
				t.Errorf("replay differs\nwant:\n%s\ngot:\n%s", want, got)
			}
		})
	}
}

func TestSectionBodyAndSplitLines(t *testing.T) {
	if got := splitLines(""); got != nil {
		t.Errorf("splitLines(empty) = %v, want no records", got)
	}
	if got := splitLines("a\n\nb"); strings.Join(got, "|") != "a||b" {
		t.Errorf("splitLines keeps blank records: %v", got)
	}
	if got := sectionBody("## H\nx\n## H\ny\n## Z\nz\n", "## H"); got != "x\ny\n" {
		t.Errorf("sectionBody = %q, want both H sections and nothing of Z", got)
	}
	if got := blockedBody("## Blocked /\nc\n## Blocked gaps\na\n## Non-investigable gaps\nb\n"); got != "a\nb\nc\n" {
		t.Errorf("blockedBody must concatenate Blocked gaps, Non-investigable gaps, Blocked / in that order: %q", got)
	}
}
