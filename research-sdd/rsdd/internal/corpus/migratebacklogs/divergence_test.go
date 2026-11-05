package migratebacklogs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The divergences of `rsdd corpus migrate-backlogs` from the frozen script (testdata/legacy). Each test asserts
// the whole output and the exit code, and runGo asserts the read-only invariant (the tree is hashed before and
// after). The legacy behaviour each one replaces is described in tool-registry.d/migrate-backlogs.md.
//
// No test branches on a host tool or on the user: the degraded paths are reached through Options.FS.

// runDivergence lays the case out and runs the command on it.
func runDivergence(t *testing.T, c dcase) result {
	t.Helper()
	root, corpus := c.layout(t)
	return runGo(t, root, corpus, c.resolveArgs(root, corpus))
}

const summary0 = "migrate-backlogs: 1 file(s) inspected · 0 with a mechanical proposal · 0 MANUAL line(s)\n"

// A file with no final newline keeps it: nothing to migrate is nothing to propose. The script's awk printed a
// newline after the last line, so every such file got a spurious one-line PROPOSE.
func TestFileWithoutFinalNewlineIsNotProposed(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", strings.TrimSuffix(state("## Gap-backlog", brow("high", "pending")), "\n")))
	want := result{Stdout: "ok x: nothing to migrate\n" + summary0}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

// The last row of a file without final newline is rewritten without gaining one: the old side carries the marker,
// and so does the new side (the script's output had a newline there, so only the old side had the marker).
func TestRewrittenLastLineKeepsTheMissingNewline(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", strings.TrimSuffix(state("## Gap-backlog", brow("high", "pending"), brow("critical", "pending")), "\n")))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -5,4 +5,4 @@\n" +
		" | Priority | Gap | Artifact type / source | Status |\n |---|---|---|---|\n | high | G1 | web | pending |\n" +
		"-| critical | G2 | web | pending |\n\\ No newline at end of file\n+| high | G2 | web | pending |\n\\ No newline at end of file\n" +
		"migrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 0 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// The FOCUSES.md pass keeps a missing final newline too.
func TestFocusesWithoutFinalNewline(t *testing.T) {
	t.Parallel()
	c := dcase{name: "x", files: map[string]string{
		"RESEARCH-STATE-a.md": state("## Gap-backlog", brow("high", "pending")),
		"FOCUSES.md":          strings.TrimSuffix(focusesTable("| a | closed | x |"), "\n"),
	}}
	got := runDivergence(t, c)
	want := "ok a: nothing to migrate\nPROPOSE FOCUSES FOCUSES.md\n--- a/FOCUSES.md\n+++ b/FOCUSES.md\n@@ -2,4 +2,4 @@\n \n | Focus | Status | State |\n |---|---|---|\n" +
		"-| a | closed | x |\n\\ No newline at end of file\n+| a | stopped | x |\n\\ No newline at end of file\n" +
		"migrate-backlogs: 2 file(s) inspected · 1 with a mechanical proposal · 0 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// A skeleton appended to a file without final newline terminates its last line, as any appended text must.
func TestSkeletonTerminatesTheLastLine(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", "# R\n\nno backlog"))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -1,3 +1,8 @@\n # R\n \n-no backlog\n\\ No newline at end of file\n+no backlog\n+\n+## Gap-backlog\n+\n+| Priority | Gap | Artifact type / source | Status |\n+|---|---|---|---|\n" +
		"MANUAL x empty-backlog-skeleton rows=1 first-line=0\nmigrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 1 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// A CRLF file reads like its LF self and every line keeps its CRLF. The script saw a phantom last cell on every
// row ("\r" after the closing pipe), reported each row as malformed, and never recognised a heading.
func TestCRLFFileIsReadAndKeepsItsLineEndings(t *testing.T) {
	t.Parallel()
	body := strings.ReplaceAll(state("## Gap backlog", brow("critical", "open"), brow("med (x)", "queued")), "\n", "\r\n")
	got := runDivergence(t, one("x", body))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -1,8 +1,8 @@\n # S\r\n \r\n" +
		"-## Gap backlog\r\n+## Gap-backlog\r\n \r\n | Priority | Gap | Artifact type / source | Status |\r\n |---|---|---|---|\r\n" +
		"-| critical | G1 | web | open |\r\n-| med (x) | G2 | web | queued |\r\n+| high | G1 | web | pending |\r\n+| medium | G2 | web | pending (x) |\r\n" +
		"migrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 0 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// A table ends at the first line that is not a row. The header of a SECOND table in the same section is a header,
// not a data row of the first: the script reported it as a malformed row.
func TestSecondTableHeaderIsNotADataRow(t *testing.T) {
	t.Parallel()
	body := state("## Gap-backlog", brow("high", "pending")) + "\n| Area | Covered |\n|---|---|\n| a | yes |\n"
	got := runDivergence(t, one("x", body))
	want := "MANUAL x unsupported-table-width cols=2 rows=1 first-line=10\n" +
		"migrate-backlogs: 1 file(s) inspected · 0 with a mechanical proposal · 1 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// The rows of a table that restarts after a break are not rewritten without a header and separator of their own:
// a table is a header, a delimiter row and its rows (GFM), and a loose row is prose.
func TestLooseRowsAfterABreakAreNotRewritten(t *testing.T) {
	t.Parallel()
	body := state("## Gap-backlog", brow("high", "pending")) + "\n| critical | G9 | web | open |\n"
	got := runDivergence(t, one("x", body))
	if got.RC != 0 || got.Stdout != "ok x: nothing to migrate\n"+summary0 {
		t.Errorf("got rc=%d %q", got.RC, got.Stdout)
	}
}

// The qualifier moved to the Status cell is free text (§8b) and keeps its case. The script lowercased it.
func TestQualifierKeepsItsCase(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", state("## Gap-backlog", brow("MED (Cross-Vibra B4)", "open"), brow("**High** (Note)", "pending"))))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -4,5 +4,5 @@\n \n | Priority | Gap | Artifact type / source | Status |\n |---|---|---|---|\n" +
		"-| MED (Cross-Vibra B4) | G1 | web | open |\n-| **High** (Note) | G2 | web | pending |\n+| medium | G1 | web | pending (Cross-Vibra B4) |\n+| high | G2 | web | pending (Note) |\n" +
		"migrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 0 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// A qualified priority over an empty Status cell gives the cell the qualifier between single blanks. The script
// doubled the cell's blanks around it.
func TestQualifierOverABlankStatusCell(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", state("## Gap-backlog", "| med (x) | G | web |   |")))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -4,4 +4,4 @@\n \n | Priority | Gap | Artifact type / source | Status |\n |---|---|---|---|\n" +
		"-| med (x) | G1 | web |   |\n+| medium | G1 | web | (x) |\n" +
		"MANUAL x unknown-status-token rows=1 first-line=7\nmigrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 1 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}

// A corpus directory that is a symlink is followed. The script searched the link itself, found nothing and said
// the corpus had no state files.
func TestSymlinkedCorpusDirectoryIsFollowed(t *testing.T) {
	t.Parallel()
	c := one("x", state("## Gap-backlog", brow("critical", "pending")))
	root, corpus := c.layout(t)
	link := filepath.Join(root, "link")
	if err := os.Symlink(corpus, link); err != nil {
		t.Fatal(err)
	}
	got := runGo(t, root, corpus, []string{link})
	if got.RC != 0 || !strings.HasPrefix(got.Stdout, "PROPOSE x RESEARCH-STATE-x.md\n") || strings.Contains(got.Stdout, "absent-input") {
		t.Errorf("got rc=%d %q", got.RC, got.Stdout)
	}
}

// A target given with trailing slashes reports the same relative names as without them. The script left the
// target in the file name of the diff labels when it ended in a slash.
func TestTrailingSlashDoesNotLeakIntoTheLabels(t *testing.T) {
	t.Parallel()
	c := one("x", state("## Gap-backlog", brow("critical", "pending")))
	root, corpus := c.layout(t)
	plain := runGo(t, root, corpus, []string{corpus})
	slashed := runGo(t, root, corpus, []string{corpus + "//"})
	if plain.RC != 0 || plain != slashed {
		t.Errorf("trailing slashes changed the report:\nplain:   %+v\nslashed: %+v", plain, slashed)
	}
}

// A corpus that lives under a directory named .git is read. The script excluded every path that contained
// `/.git/`, the corpus's own location included, and said there was nothing to migrate.
func TestCorpusUnderADotGitDirectoryIsRead(t *testing.T) {
	t.Parallel()
	root, _ := dcase{}.layout(t)
	inner := filepath.Join(root, ".git", "corpus")
	if err := os.MkdirAll(inner, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inner, "RESEARCH-STATE-x.md"), []byte("# R\n\nno backlog\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := runGo(t, root, inner, []string{inner})
	if got.RC != 0 || !strings.Contains(got.Stdout, "MANUAL x empty-backlog-skeleton") {
		t.Errorf("got rc=%d %q", got.RC, got.Stdout)
	}
}

// A directory that happens to be named like a state file is not one. The script handed it to awk and ended with
// a degraded exit.
func TestDirectoryNamedLikeAStateFileIsSkipped(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, dcase{files: map[string]string{
		"RESEARCH-STATE-d.md/": "", "RESEARCH-STATE-d.md/RESEARCH-STATE-in.md": "# R\n\nno backlog\n", "FOCUSES.md/": "",
	}})
	if got.RC != 0 || !strings.Contains(got.Stdout, "PROPOSE in RESEARCH-STATE-d.md/RESEARCH-STATE-in.md\n") || strings.Contains(got.Stdout, "MANUAL d ") {
		t.Errorf("got rc=%d %q", got.RC, got.Stdout)
	}
}

// Proposing is idempotent: the text a proposal leads to has nothing mechanical left to propose, for every
// parity fixture, state files and FOCUSES.md alike. (The bash suite applies the real diff with patch.)
func TestApplyingTheProposalLeavesNothingMechanical(t *testing.T) {
	t.Parallel()
	for _, c := range allCases() {
		for p, content := range c.files {
			name := filepath.Base(p)
			if content == "" || !strings.HasSuffix(name, ".md") || !(strings.HasPrefix(name, "RESEARCH-STATE") || name == "FOCUSES.md") {
				continue
			}
			transform := func(l []line) ([]line, []manualItem) { return migrateBacklog(l, false) }
			if name == "FOCUSES.md" {
				transform = migrateFocuses
			}
			once, _ := transform(splitLines(content))
			twice, _ := transform(once)
			if d := unifiedDiff(p, once, twice); d != "" {
				t.Errorf("%s/%s: a second pass still proposes:\n%s", c.name, p, d)
			}
		}
	}
}

// A rewritten line that equals its neighbour is a tie for diff(1): GNU diff may print the equivalent hunk the
// other way round. The port prints the positional hunk, which is always a valid patch.
func TestTieLinesArePrintedPositionally(t *testing.T) {
	t.Parallel()
	got := runDivergence(t, one("x", "# S\n\n## Gap-backlog\n\n"+tblHdr+"| critical | G | web | pending |\n| high | G | web | pending |\n"))
	want := "PROPOSE x RESEARCH-STATE-x.md\n--- a/RESEARCH-STATE-x.md\n+++ b/RESEARCH-STATE-x.md\n@@ -4,5 +4,5 @@\n \n | Priority | Gap | Artifact type / source | Status |\n |---|---|---|---|\n" +
		"-| critical | G | web | pending |\n+| high | G | web | pending |\n | high | G | web | pending |\n" +
		"migrate-backlogs: 1 file(s) inspected · 1 with a mechanical proposal · 0 MANUAL line(s)\n"
	if got.RC != 0 || got.Stdout != want {
		t.Errorf("got rc=%d %q, want %q", got.RC, got.Stdout, want)
	}
}
