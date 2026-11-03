//go:build !nodiff && unix

package gaprows

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Differential tests: the frozen lib/gap-rows.sh (testdata/legacy, the bytes before the port) and this package must
// agree on gap_rows_parse, gap_bullet_text and gap_overlap. A host without bash or GNU awk FAILS the test with a typed
// message: a skipped differential proves nothing.

var (
	oracleOnce sync.Once
	oracleErr  error
)

func requireOracle(t *testing.T) {
	t.Helper()
	oracleOnce.Do(func() {
		for _, tool := range []string{"bash", "awk"} {
			if _, err := exec.LookPath(tool); err != nil {
				oracleErr = fmt.Errorf("oracle tool %q not on PATH: %w", tool, err)
				return
			}
		}
		out, err := exec.Command("awk", "--version").CombinedOutput()
		if err != nil || !strings.HasPrefix(string(out), "GNU Awk") {
			oracleErr = fmt.Errorf("the default awk is not GNU awk (gawk): %q", strings.SplitN(string(out), "\n", 2)[0])
		}
	})
	if oracleErr != nil {
		t.Fatalf("differential: the oracle host is incomplete; gaprows is NOT proven against lib/gap-rows.sh: %v", oracleErr)
	}
}

var legacyLib, legacyLibErr = filepath.Abs(filepath.Join("testdata", "legacy", "gap-rows.sh"))

// bash runs one function of the frozen lib. Its stdout and exit code are returned.
func bash(t *testing.T, fn string, args ...string) (string, int) {
	t.Helper()
	requireOracle(t)
	if legacyLibErr != nil {
		t.Fatalf("differential: cannot resolve the oracle path: %v", legacyLibErr)
	}
	cmd := exec.Command("bash", append([]string{"-c", `. "$1"; shift; fn=$1; shift; "$fn" "$@"`, "_", legacyLib, fn}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "LC_ALL=C.UTF-8"}
	out, err := cmd.Output()
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("legacy %s: %v", fn, err)
		}
		code = ee.ExitCode()
	}
	return string(out), code
}

func writeTemp(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "in.md")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// legacyShape renders Go records the way gap_rows_parse prints them.
func legacyShape(tb Table) string {
	var b strings.Builder
	for _, r := range tb.Records {
		switch r.Kind {
		case KindRow:
			st := "other"
			if r.Pending {
				st = "pending"
			}
			fmt.Fprintf(&b, "ROW\t%s\t%s\t%s\t%s\n", r.ID, r.Block, st, r.Text)
		case KindSkipped:
			fmt.Fprintf(&b, "SKIPPED\t%s\n", r.Cell)
		case KindUnparsed:
			fmt.Fprintf(&b, "UNPARSED\t%s\n", r.Source)
		}
	}
	return b.String()
}

func assertParse(t *testing.T, name, src string) {
	t.Helper()
	want, code := bash(t, "gap_rows_parse", writeTemp(t, src))
	if code != 0 {
		t.Fatalf("%s: legacy gap_rows_parse exited %d", name, code)
	}
	if got := legacyShape(Parse(src)); got != want {
		t.Errorf("%s: Parse differs from gap_rows_parse\nlegacy: %q\ngo:     %q", name, want, got)
	}
}

func assertBullet(t *testing.T, name, src, id string) {
	t.Helper()
	want, code := bash(t, "gap_bullet_text", writeTemp(t, src), id)
	got, found := Bullet(src, id)
	switch {
	case code == 0 && !found:
		t.Errorf("%s %s: legacy found %q, Go found nothing", name, id, want)
	case code == 1 && found:
		t.Errorf("%s %s: legacy found nothing, Go found %q", name, id, got)
	case code >= 2:
		t.Fatalf("%s %s: legacy exited %d", name, id, code)
	case code == 0 && got+"\n" != want:
		t.Errorf("%s %s: bullet differs\nlegacy: %q\ngo:     %q", name, id, want, got+"\n")
	}
}

func assertOverlap(t *testing.T, name, row, bullet string) {
	t.Helper()
	out, code := bash(t, "gap_overlap", row, bullet)
	if code != 0 {
		t.Fatalf("%s: legacy gap_overlap exited %d", name, code)
	}
	s, n := Overlap(row, bullet)
	if want := fmt.Sprintf("%d %d\n", s, n); out != want {
		t.Errorf("%s: overlap legacy %q, go %q (row %q, bullet %q)", name, out, want, row, bullet)
	}
}

func TestDifferentialFixtures(t *testing.T) {
	states := map[string]string{
		"single":       "| high | B1-G2 how it works | w | pending |\n",
		"three":        tbl + "| high | B1-G1 first | w | pending |\n| low | B2-G1 middle | w | done |\n| medium | B3-G1 last | w | Pending review |",
		"escaped":      "| high | B4-G1 a \\| b \\\\| c | w | pending |\n",
		"crlf":         "| high | B5-G1 text | w | pending |\r\n| — | B5-G2 old | w | done |\r\n| high | B5-G3 x |\r\n",
		"closed":       "| — | B1-G1 a | w | done |\n| ~~low~~ | B1-G2 b | w | done |\n| 7 | B1-G3 c | w | pending |\n| 7 | B1-G4 d | w | done |\n| — | B1-G5 e | pending |\n",
		"unparsed":     "| urgent | B1-G1 x | w | pending |\n| high | B1-G2 x |\n| high | B1-G3 " + strings.Repeat("y", 120) + " | w | pending |\n",
		"empty":        "",
		"no-rows":      "# title\nsome text\n",
		"tabs":         "| high | B1-G1 a\tb | w | pending |\n",
		"indented":     "   \t| high | B8-G1 x | w | pending |   \n",
		"bare pipes":   "|\n||\n| |\n|||\n",
		"no final nl":  "| high | B9-G1 x | w | pending |",
		"uppercase":    "| high | B9-G1 x | w | PENDING |\n| high | B9-G2 x | w | Pend |\n",
		"id forms":     "| high | B9-G1x glued | w | pending |\n| high | B9-G | w | pending |\n| high | B-G1 x | w | pending |\n",
		"empty cells":  "| | B1-G1 x | | pending |\n| high | B1-G2 x | | |\n",
		"em-dash mid":  "| a — b | B1-G1 x | w | pending |\n",
		"leading zero": "| high | B01-G002 x | w | pending |\n",
	}
	for name, src := range states {
		assertParse(t, name, src)
	}
	blocks := map[string]string{
		"forms":   "- **B1-G1** a\n* **[B1-G2]** b\n- **B1-G3 (open, n)** c\n- **B1-G4**: d\n  - **B1-G5** nested\n- **B1-G10** ten\n",
		"cont":    "- **B1-G1** first\nsecond\n  third\n1\n2\n3\n4\n5\n6\n7\n8\n\n- **B1-G2** after\n",
		"stops":   "- **B1-G1** x\n## H\n- **B1-G2** y\n- **B1-G3** z\nmore\n- **B1-G4** w\n \t \nzz\n",
		"crlf":    "- **B1-G1** first\r\nmore\r\n",
		"twice":   "- **B1-G1** one\n\n- **B1-G1** two\n",
		"nonl":    "- **B1-G1** last",
		"prose":   "see B1-G1 here\n**B1-G1** bare\n",
		"nothing": "",
	}
	for name, src := range blocks {
		for _, id := range []string{"B1-G1", "B1-G2", "B1-G3", "B1-G4", "B1-G5", "B1-G10", "B1-G9"} {
			assertBullet(t, name, src, id)
		}
	}
	for _, c := range [][2]string{
		{"widgets frobnicate sprockets", "- **B1-G1** widgets frobnicate sprockets"},
		{"cats and dogs", "widgets"}, {"the of an", "the of an"}, {"months", "month"}, {"class", "clas"},
		{"bosses", "boss"}, {"Widgets WIDGET", "widget"}, {"9.5.0 1166 v2", "9.5.0 1166 v2"}, {"a.b_c x.y", "a.b_c"},
		{"a b c d", "a b c d"}, {"", "x"}, {"naïve café", "naive cafe"}, {"foo-bar baz_qux", "foo bar baz_qux"},
		{`back\slash and "quotes"`, `back\slash`}, {"-e -n", "-e"}, {"price: 3.5 USDs", "usd"}, {"tokens.", "token."},
	} {
		assertOverlap(t, "fixture", c[0], c[1])
	}
}

var genWords = []string{"widgets", "widget", "frobnicate", "sprocket", "the", "of", "Q.x", "a", "b1", "ab", "class", "bosses", "9.5", "1166",
	"foo_bar", "x.y.z", "naïve", "über", "months", "month", "pending", "—", "~~", "\\|", "`code`", "B1-G1", "B1-G2"}

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
	stats := []string{"pending", "Pending: wait", "done", "closed", "", "pend", "PENDING"}
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

// TestDifferentialGenerated runs a seeded corpus of generated state files, block files and word lists against the
// frozen lib. The seed is fixed so a failure reproduces.
func TestDifferentialGenerated(t *testing.T) {
	r := rand.New(rand.NewSource(2645))
	for i := 0; i < 60; i++ {
		var s, b strings.Builder
		for l, n := 0, r.Intn(14); l < n; l++ {
			s.WriteString(genStateLine(r) + "\n")
		}
		for l, n := 0, r.Intn(16); l < n; l++ {
			b.WriteString(genBlockLine(r) + "\n")
		}
		state, block := s.String(), b.String()
		if r.Intn(4) == 0 {
			state = strings.TrimSuffix(state, "\n")
		}
		name := fmt.Sprintf("gen-%d", i)
		assertParse(t, name, state)
		for g := 0; g < 3; g++ {
			assertBullet(t, name, block, fmt.Sprintf("B%d-G%d", r.Intn(3), r.Intn(12)))
		}
		assertOverlap(t, name, genText(r, r.Intn(8)), genText(r, r.Intn(10)))
	}
}

// The frozen oracle is pinned by hash, so an edit to it cannot go unnoticed.
func TestLegacyOracleIsPinned(t *testing.T) {
	sums, err := os.ReadFile(filepath.Join("testdata", "legacy", "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		want, rel, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 {
			t.Fatalf("malformed SHA256SUMS line %q", line)
		}
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", rel))
		if err != nil {
			t.Fatalf("pinned file missing: %v", err)
		}
		if got := sha256.Sum256(b); hex.EncodeToString(got[:]) != want {
			t.Errorf("%s changed: sha256 %x, pinned %s", rel, got, want)
		}
		n++
	}
	if n != 1 {
		t.Errorf("%d files pinned; the oracle is lib/gap-rows.sh alone", n)
	}
}
