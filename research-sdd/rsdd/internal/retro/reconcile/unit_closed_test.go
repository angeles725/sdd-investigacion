package reconcile

import (
	"context"
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestEvidenceCommits(t *testing.T) {
	cases := []struct {
		name, rec string
		want      []string
	}{
		{"commit line, sorted unique", "Commit: bbbbbb1 aaaaaa2 bbbbbb1\n", []string{"aaaaaa2", "bbbbbb1"}},
		{"plural and any case", "COMMITS abcdef1\n", []string{"abcdef1"}},
		{"no commit word, no tokens", "see abcdef1\n", nil},
		{"word needs boundaries", "recommitted abcdef1 and commitment abcdef2\n", nil},
		{"7 to 40 characters", "commit 123456 1234567 " + "1234567890123456789012345678901234567890" + " 12345678901234567890123456789012345678901\n",
			[]string{"1234567", "1234567890123456789012345678901234567890"}},
		{"a digit is required", "commit abcdefa 1abcdef\n", []string{"1abcdef"}},
		{"separators other than space", "commit:abcdef1,abcdef2/abcdef3\n", []string{"abcdef1", "abcdef2", "abcdef3"}},
		{"non-hex letters split a token", "commit abcdefg1234567\n", []string{"1234567"}},
		{"a token at the start of the line", "abcdef1 is the commit\n", []string{"abcdef1"}},
	}
	for _, c := range cases {
		if got := evidenceCommits(c.rec); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestEvidenceHasTest(t *testing.T) {
	cases := []struct {
		name, rec string
		want      bool
	}{
		{"suffix form", "Test: a/b.test.sh\n", true},
		{"go suffix form", "tests: pkg/x_test.go\n", true},
		{"prefix form", "test test_thing.py\n", true},
		{"directory form", "Tests in tests/x\n", true},
		{"word without a path", "Test: passes\n", false},
		{"path without the word", "see contest_x.go\n", false},
		{"word and path on different lines", "Test: passes\nsee contest_x.go\n", false},
		{"upper case word, case-sensitive path", "TEST x.test.sh\n", true},
		{"path form is case-sensitive", "test x.TEST.sh\n", false},
	}
	for _, c := range cases {
		if got := evidenceHasTest(c.rec); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestClosedRecords(t *testing.T) {
	const p = "t/retros/r.md"
	sig := func(id string) string { return "Source retro: " + p + " · " + id }
	cases := []struct {
		name, bodies, row string
		want              string
		ignored           int
	}{
		{"separated: only separators split", sig("1") + "\nnote\n\x1e\n" + sig("2") + "\nother", "2", sig("2") + "\nother\n", 0},
		{"separated: a footer signature keeps the whole issue", "body\nCommit: abc1234\n" + sig("1") + "\n\x1e\nzzz", "1", "body\nCommit: abc1234\n" + sig("1") + "\n", 0},
		{"unseparated: split per signature line", sig("1") + "\none\n" + sig("2") + "\ntwo", "2", sig("2") + "\ntwo\n", 0},
		{"unseparated: the preamble is counted", "a\nb\n" + sig("1") + "\none", "1", sig("1") + "\none\n", 2},
		{"unseparated: nothing started, everything ignored", "a\nb", "1", "", 2},
		{"row id is the whole token", sig("11"), "1", "", 0},
		{"two matching issues are concatenated", sig("1") + "\nx\n\x1e\n" + sig("1") + "\ny", "1", sig("1") + "\nx\n" + sig("1") + "\ny\n", 0},
		{"other retro's signature", "Source retro: t/retros/other.md · 1", "1", "", 0},
		{"signature in mid-line", "see " + sig("1") + " now", "1", "see " + sig("1") + " now\n", 0},
	}
	for _, c := range cases {
		got, ign := closedRecords(c.bodies, p, c.row)
		if got != c.want || ign != c.ignored {
			t.Errorf("%s: got (%q, %d), want (%q, %d)", c.name, got, ign, c.want, c.ignored)
		}
	}
}

func TestIssueNumbers(t *testing.T) {
	if got, want := issueNumbers("Closed-issue-number: 9\nClosed-issue-number:   12  \nClosed-issue-number: 9\nClosed-issue-number: x\n x Closed-issue-number: 4\n"), "#12, #9"; got != want {
		t.Errorf("issueNumbers = %q, want %q (unique, bytewise sorted, whole lines only)", got, want)
	}
	if got := issueNumbers("none\n"); got != "" {
		t.Errorf("issueNumbers without numbers = %q, want empty", got)
	}
}

// TestRunClosedReport pins the Report API of the closed-issue classes: the typed fields, not the rendered text.
func TestRunClosedReport(t *testing.T) {
	c := regressedCases()[0] // reproposed-in-a-later-retro: row 1 shipped and regressed, row 2 untracked
	b := mkBox(t, c)
	rep, err := Run(t.Context(), Options{
		Retro: b.arg, IssuesCache: CacheBodies(""), ClosedCache: ClosedFile(b.closedArg), KitRoot: b.root, Cwd: b.cwd,
		Env: func(k string) string {
			return map[string]string{"PATH": os.Getenv("PATH"), "RECONCILE_ISSUES_GIT_DIR": b.env["RECONCILE_ISSUES_GIT_DIR"]}[k]
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Shipped) != 1 || rep.Shipped[0].Row != "1" || rep.Shipped[0].Why != fixMain {
		t.Errorf("Shipped = %+v, want row 1 with the reachable commit", rep.Shipped)
	}
	if len(rep.Regressed) != 1 || rep.Regressed[0].Row != "1" || !strings.Contains(rep.Regressed[0].Why, "closed by #12, re-proposed in "+laterRetro+" as row 5") {
		t.Errorf("Regressed = %+v", rep.Regressed)
	}
	if len(rep.Untracked) != 1 || rep.Untracked[0].Row != "2" || len(rep.Borderline) != 0 || rep.Degraded != "" {
		t.Errorf("Untracked = %+v Borderline = %+v Degraded = %q", rep.Untracked, rep.Borderline, rep.Degraded)
	}
}

// TestRunClosedDegradedKeepsTheRows: a repository check that cannot verify reachability is a Degraded report whose
// rows are still borderline, never shipped.
func TestRunClosedDegradedKeepsTheRows(t *testing.T) {
	c := closedCases()[0]
	c.repo = ""
	b := mkBox(t, c)
	rep, err := Run(t.Context(), Options{
		Retro: b.arg, IssuesCache: CacheBodies(""), ClosedCache: ClosedBodies(shippedBody(fixMain)), KitRoot: b.root, Cwd: b.cwd,
		Env: func(k string) string { return map[string]string{"PATH": os.Getenv("PATH")}[k] },
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(rep.Degraded, "degraded: ") || len(rep.Shipped) != 0 || len(rep.Borderline) != 1 {
		t.Errorf("Degraded = %q Shipped = %+v Borderline = %+v", rep.Degraded, rep.Shipped, rep.Borderline)
	}
	if rc := rep.Render(io.Discard, io.Discard); rc != 1 {
		t.Errorf("Render = %d, want 1", rc)
	}
}

func TestRunClosedHonoursTheContext(t *testing.T) {
	b := mkBox(t, closedCases()[0])
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err := Run(ctx, Options{Retro: b.arg, IssuesCache: CacheBodies(""), ClosedCache: ClosedBodies(""), KitRoot: b.root, Cwd: b.cwd, Env: func(string) string { return "" }})
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v, want context.Canceled", err)
	}
}
