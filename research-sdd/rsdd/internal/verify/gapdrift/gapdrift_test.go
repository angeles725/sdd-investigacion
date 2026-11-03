package gapdrift

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func openCheck(t *testing.T, files map[string]string, st string, o Options) Result {
	t.Helper()
	dir := corpus(t, files)
	c, err := OpenCorpus(dir, dir)
	if err != nil {
		t.Fatal(err)
	}
	res, err := c.Check(st, "STATE", o)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestTypedOutcomes(t *testing.T) {
	blk := map[string]string{"t-block1.md": bullets1c}
	for _, c := range []struct {
		name  string
		state string
		o     Options
		want  Outcome
	}{
		{"empty-input", "", Options{Threshold: 20}, OutcomeEmptyInput},
		{"no-match: text without rows", "# s\nno table\n", Options{Threshold: 20}, OutcomeNoRows},
		{"no-match: only closed rows", state(row("—", "B1-G1 x", "done")), Options{Threshold: 20, All: true}, OutcomeNoRows},
		{"no-match: only unparsed rows", state(row("urgent", "B1-G1 x", "pending")), Options{Threshold: 20}, OutcomeNoRows},
		{"no pending rows", state(row("high", "B1-G1 x", "done")), Options{Threshold: 20}, OutcomeNoPending},
		{"degraded: no block", state(row("high", "B9-G1 x", "pending")), Options{Threshold: 20}, OutcomeDegraded},
		{"checked", state(row("high", "B1-G1 widgets frobnicate", "pending")), Options{Threshold: 20}, OutcomeChecked},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := openCheck(t, blk, c.state, c.o).Outcome; got != c.want {
				t.Errorf("Outcome = %d, want %d", got, c.want)
			}
		})
	}
}

const bullets1c = "- **B1-G1** widgets frobnicate sprockets\n"

func TestFindingsAreGroupedInReportOrder(t *testing.T) {
	res := openCheck(t, map[string]string{"t-block1.md": bullets1c}, state(
		row("urgent", "B1-G1 x", "pending"), row("high", "B2-G1 x y z", "pending"), row("high", "B1-G7 prose", "pending"),
		row("high", "B1-G1 cats dogs birds", "pending"), row("high", "B1-G1 9.5.0", "pending")), Options{Threshold: 20})
	var kinds []FindingKind
	for _, f := range res.Findings {
		kinds = append(kinds, f.Kind)
	}
	want := []FindingKind{FindingDrift, FindingNoBullet, FindingNoBlock, FindingNoWords, FindingUnparsed}
	if len(kinds) != len(want) {
		t.Fatalf("kinds %v, want %v", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Errorf("kinds %v, want %v", kinds, want)
		}
	}
	if res.ExitCode() != 1 {
		t.Errorf("exit %d, want 1 with a suspect", res.ExitCode())
	}
}

func TestThresholdIsDecimal(t *testing.T) {
	// B1-G1 shares 1 of 2 words: 50 %. The script read 010 as octal 8 and 08 aborted its loop (D1).
	files := map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets cats", "pending")), "t-block1.md": bullets1c}
	d := corpus(t, files)
	for th, wantSuspect := range map[string]bool{"051": true, "050": false, "08": false, "010": false, "000": false, "0": false} {
		got := runGo(d, d, "--threshold", th)
		if suspects := strings.Contains(got.stdout, "DRIFT?"); suspects != wantSuspect {
			t.Errorf("--threshold %s: output %q, suspect=%v want %v", th, got.stdout, suspects, wantSuspect)
		}
		if !strings.Contains(got.stdout, "checked=1 ") {
			t.Errorf("--threshold %s: the row was not checked: %q", th, got.stdout)
		}
	}
}

func TestWorktreePruneIsLiteral(t *testing.T) {
	files := map[string]string{
		"RESEARCH-STATE.md":               state(row("high", "B5-G1 widgets", "pending")),
		".claude/worktrees/w/t-block5.md": bullets1c,
	}
	d := corpus(t, files)
	for _, target := range []string{d, d + "/"} { // the script disabled the prune for a trailing slash (D2)
		got := runGo(d, target, "--state", d+"/RESEARCH-STATE.md")
		if !strings.Contains(got.stdout, "NO-BLOCK B5-G1") {
			t.Errorf("target %q: a nested worktree's block file was used: %q", target, got.stdout)
		}
	}
	// A glob character in the target path no longer reaches the prune pattern (D2).
	g := filepath.Join(t.TempDir(), "a[b]*")
	for name, body := range map[string]string{"RESEARCH-STATE.md": files["RESEARCH-STATE.md"], "t-block5.md": "- **B5-G1** widgets\n"} {
		if err := os.MkdirAll(g, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(g, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := runGo(g, g); !strings.Contains(got.stdout, "checked=1 ") {
		t.Errorf("glob-character target: %q", got.stdout)
	}
}

func TestBlockFilesAreTriedInPathOrder(t *testing.T) {
	// Both files define B1-G1; the bytewise-first path is the source (the script used readdir order, D3).
	files := map[string]string{
		"RESEARCH-STATE.md": state(row("high", "B1-G1 zebra yak", "pending")),
		"a-block1.md":       "- **B1-G1** zebra yak\n",
		"b-block1.md":       "- **B1-G1** completely other words\n",
	}
	if got := runGo(corpus(t, files), "."); !strings.Contains(got.stdout, "suspects=0") {
		t.Errorf("output %q, want the a-block1.md bullet to win", got.stdout)
	}
}

func TestUnparsedLineIsPrintedWhole(t *testing.T) {
	d := corpus(t, map[string]string{"RESEARCH-STATE.md": "| high\t| B1-G1 x\t|\n", "t-block1.md": bullets1c}) // D4
	got := runGo(d, d)
	if !strings.Contains(got.stdout, "UNPARSED | high\t| B1-G1 x\t|\n") {
		t.Errorf("output %q, want the whole line", got.stdout)
	}
}

func TestRowTextCutIsNinetyCharacters(t *testing.T) { // D5
	text := strings.Repeat("ñ", 100)
	d := corpus(t, map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats "+text, "pending")), "t-block1.md": "- **B1-G1** zzz yyy\n"})
	out := runGo(d, d).stdout
	if want := "row='cats " + strings.Repeat("ñ", 85) + "'\n"; !strings.Contains(out, want) {
		t.Errorf("output %q, want the row cut at 90 characters", out)
	}
	if cutChars("a\xffb", 2) != "a\xff" {
		t.Errorf("an invalid byte must count as one character")
	}
}

func TestOperationalErrorsAreTyped(t *testing.T) {
	d := corpus(t, map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "t-block1.md": bullets1c})
	c, err := OpenCorpus(d, d)
	if err != nil {
		t.Fatal(err)
	}
	c.read = func(string) ([]byte, error) { return nil, os.ErrPermission }
	_, err = c.Check(state(row("high", "B1-G1 widgets", "pending")), "S", Options{Threshold: 20})
	var e *Error
	if !errors.As(err, &e) || e.Kind != ErrReadBlock || !strings.HasPrefix(e.Msg, "check-gap-drift: cannot read ") || !errors.Is(err, os.ErrPermission) {
		t.Errorf("err = %v, want a typed ErrReadBlock wrapping the cause", err)
	}
	if _, err := OpenCorpus("", filepath.Join(d, "missing")); !errors.As(err, &e) || e.Kind != ErrListBlocks || e.Msg != "check-gap-drift: cannot list block files under "+filepath.Join(d, "missing") {
		t.Errorf("OpenCorpus on a missing dir: %v", err)
	}
}

func TestCorpusIsReusedAcrossStates(t *testing.T) {
	d := corpus(t, map[string]string{"t-block1.md": bullets1c})
	c, err := OpenCorpus(d, d)
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	real := c.read
	c.read = func(p string) ([]byte, error) { reads++; return real(p) }
	for i := 0; i < 3; i++ {
		if _, err := c.Check(state(row("high", "B1-G1 widgets", "pending")), "S", Options{Threshold: 20}); err != nil {
			t.Fatal(err)
		}
	}
	if reads != 1 || c.BlockFiles() != 1 {
		t.Errorf("block file read %d times for 3 states (want 1); %d block files", reads, c.BlockFiles())
	}
}
