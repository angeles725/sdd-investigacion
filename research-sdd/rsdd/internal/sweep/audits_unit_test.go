package sweep

import (
	"bytes"
	"math"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Guard-to-test table for the pieces of `sweep audits` that the scenario table and the golden reach only through
// a report (each boundary was mutated by hand once; the mutant turns the named test red):
//
//	-path '*/audits/*.md' matches the whole path, first /audits/   TestAuditsInAuditsPath
//	find lists audits, never an index, a .git file or a non-.md    TestAuditsFindAudits
//	a claim is "| <n> |" with blanks only inside                   TestCountClaims
//	a directory counts 0 claims, an unreadable file "?"            TestAuditClaimsStates
//	RSDD_RETRO_AGE_DAYS reads like `[ n -gt v ]`                   TestAuditAgeDays
//	age is whole days, a future date is 0                          TestAuditAgeDaysOf
//	escalation is strictly past the threshold                      TestAuditEscalation
//	every git add-date call passes --no-renames                    TestAddedDateArgs, TestEveryAuditAddDateCallPassesNoRenames
//	the add date falls back to mtime, then to now                  TestAddedEpoch
//	the queue is oldest first, ties bytewise                       TestSortAuditRows
//	the Summary lines and the "Nothing to review." gate            TestWriteAuditsReport
//	truncated targets are counted and named word by word           TestAuditSkipped
//	only applied and dismissed close an audit                      TestAuditClosed, TestAuditStatusLabel
//	[ -d ] follows a link and refuses a file                       TestIsDirectory
//	an unreadable audit reads as no marker                         TestAuditStatus
//	kit resolution and the operational exits                       TestAuditsOperationalExits
//	the hook filter and its envelope                               TestAuditsSummaryFilter*, TestAuditsHookContext, TestAuditsHookCommand*

func TestAuditsInAuditsPath(t *testing.T) {
	for p, want := range map[string]bool{
		"/t/audits/a.md": true, "/t/x/audits/a.md": true, "/t/audits/sub/a.md": true, "/audits/.md": true, "/audits/a.md": true,
		"/t/audits/a.txt": false, "/t/audits": false, "/t/audits/": false, "/t/audits/md": false, "/t/audits/.m": false,
		"/t/audits/a.md.txt": false, "/t/aaudits/a.md": false, "audits/a.md": false, "/t/retros/a.md": false,
		"/x/audits/targetA/note.md": true, // the prefix of the target counts: the whole path is matched
		"/t/audits/b/audits/c.md":   true,
	} {
		if got := inAuditsPath(p); got != want {
			t.Errorf("inAuditsPath(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestAuditsFindAudits(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, f := range []string{
		"audits/a1.md", "audits/sub/deep.md", "x/y/audits/d4.md", "audits/.hidden.md",
		"x/y/z/audits/d5.md", "audits/notes.txt", "audits/AUDITS-INDEX.md", "audits/my-index-1.md", ".git/audits/g.md", "retros/r.md",
	} {
		w.put(a+"/"+f, "x\n")
	}
	got := findAudits(a)
	sort.Strings(got)
	want := []string{a + "/audits/.hidden.md", a + "/audits/a1.md", a + "/audits/sub/deep.md", a + "/x/y/audits/d4.md"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("findAudits =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if g := findAudits(a + "/nope"); len(g) != 0 {
		t.Errorf("a missing target lists %v", g)
	}
}

func TestCountClaims(t *testing.T) {
	for _, c := range []struct {
		name, in string
		want     int
	}{
		{"empty", "", 0},
		{"one row", "| 1 | a |", 1},
		{"one row with newline", "| 1 | a |\n", 1},
		{"two rows", "| 1 | a |\n| 2 | b |\n", 2},
		{"last row without newline", "x\n| 1 | a |\n| 2 | b |", 2},
		{"several digits", "| 1234 | a |\n", 1},
		{"many blanks before the number", "|    7 | a |\n", 1},
		{"no blank before the number", "|7 | a |\n", 1},
		{"no blank after the number", "| 7| a |\n", 0},
		{"two blanks after the number", "| 7  | a |\n", 0},
		{"not a number", "| x | a |\n| # | b |\n", 0},
		{"mixed digits and letters", "| 1a | a |\n", 0},
		{"indented row", " | 1 | a |\n", 0},
		{"separator row", "|---|---|\n", 0},
		{"pipe only", "| |\n", 0},
		{"row in the middle of a line", "text | 1 | a |\n", 0},
		{"CRLF rows", "| 1 | a |\r\n| 2 | b |\r\n", 2},
		{"NUL in the file", "a\x00b\n| 1 | a |\n", 1},
	} {
		if got := countClaims([]byte(c.in)); got != c.want {
			t.Errorf("%s: countClaims(%q) = %d, want %d", c.name, c.in, got, c.want)
		}
	}
}

func TestAuditClaimsStates(t *testing.T) {
	w := newWorld(t)
	w.put(w.root+"/rows.md", "| 1 | a |\n| 2 | b |\n")
	w.put(w.root+"/none.md", "nothing\n")
	w.put(w.root+"/empty.md", "")
	w.must(os.MkdirAll(w.root+"/dir.md", 0o755))
	w.must(os.Symlink(w.root+"/nowhere", w.root+"/broken.md"))
	for f, want := range map[string]string{"rows.md": "2", "none.md": "0", "empty.md": "0", "dir.md": "0", "broken.md": "?", "missing.md": "?"} {
		if got := auditClaims(w.root + "/" + f); got != want {
			t.Errorf("auditClaims(%s) = %q, want %q", f, got, want)
		}
	}
	if os.Geteuid() != 0 {
		w.put(w.root+"/locked.md", "| 1 | a |\n")
		w.must(os.Chmod(w.root+"/locked.md", 0))
		if got := auditClaims(w.root + "/locked.md"); got != "?" {
			t.Errorf("an unreadable audit has an unknown count, not %q", got)
		}
	}
}

func TestAuditAgeDays(t *testing.T) {
	for v, want := range map[string]int64{
		"": 7, "7": 7, "0": 0, "1": 1, "30": 30, "-1": -1, "+3": 3, "03": 3, "08": 8, " 4": 4, "4 ": 4, "\t5\n": 5,
		"abc": math.MaxInt64, "1.5": math.MaxInt64, "0x10": math.MaxInt64, "1_0": math.MaxInt64, "99999999999999999999": math.MaxInt64,
		"3 4": math.MaxInt64, "--1": math.MaxInt64,
	} {
		if got := auditAgeDays(v); got != want {
			t.Errorf("auditAgeDays(%q) = %d, want %d", v, got, want)
		}
	}
}

func TestAuditAgeDaysOf(t *testing.T) {
	const now = 1_800_000_000
	for _, c := range []struct{ epoch, want int64 }{
		{now, 0}, {now - 1, 0}, {now - 86399, 0}, {now - 86400, 1}, {now - 86401, 1}, {now - 3*86400, 3}, {now - 3*86400 - 86399, 3},
		{now + 1, 0}, {now + 86400, 0}, {now + 30*86400, 0}, {0, now / 86400},
	} {
		if got := auditAgeDaysOf(now, c.epoch); got != c.want {
			t.Errorf("auditAgeDaysOf(now, now%+d) = %d, want %d", c.epoch-now, got, c.want)
		}
	}
}

func TestAuditEscalation(t *testing.T) {
	for _, c := range []struct {
		age, threshold int64
		want           string
	}{
		{7, 7, ""}, {8, 7, "  ·  ESCALATED (aged 8d)"}, {6, 7, ""}, {0, 0, ""}, {1, 0, "  ·  ESCALATED (aged 1d)"}, {0, -1, "  ·  ESCALATED (aged 0d)"},
		{10950, math.MaxInt64, ""}, {365, 7, "  ·  ESCALATED (aged 365d)"},
	} {
		if got := auditEscalation(c.age, c.threshold); got != c.want {
			t.Errorf("auditEscalation(%d, %d) = %q, want %q", c.age, c.threshold, got, c.want)
		}
	}
}

func TestAddedDateArgs(t *testing.T) {
	got := strings.Join(addedDateArgs("/t/audits/a.md"), "\x00")
	want := strings.Join([]string{"log", "--no-renames", "--diff-filter=A", "--format=%aI", "-1", "--", "/t/audits/a.md"}, "\x00")
	if got != want {
		t.Errorf("addedDateArgs = %q, want %q", got, want)
	}
	if strings.Contains(got, "--follow") {
		t.Error("rename-following is the accepted tradeoff that was removed (about 15x slower per call)")
	}
}

// The structural guard of old case 14c: every `git log --diff-filter=A` call of the source carries --no-renames,
// comments excluded, so a comment cannot satisfy it.
func TestEveryAuditAddDateCallPassesNoRenames(t *testing.T) {
	src, err := os.ReadFile("audits.go")
	if err != nil {
		t.Fatal(err)
	}
	calls, withFlag := 0, 0
	for _, l := range strings.Split(string(src), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), "//") || !strings.Contains(l, `"--diff-filter=A"`) {
			continue
		}
		calls++
		if strings.Contains(l, `"--no-renames"`) {
			withFlag++
		}
	}
	if calls != 1 || withFlag != 1 {
		t.Errorf("%d git log --diff-filter=A calls, %d with --no-renames; the one add-date call needs it", calls, withFlag)
	}
}

func TestAddedEpoch(t *testing.T) {
	w := newWorld(t)
	g := git.Runner{Env: w.environ(), Timeout: retroGitTimeout, MaxBytes: retroGitMaxBytes, Now: func() time.Time { return w.now }}
	now := w.now.Unix()

	plain := w.tgt("plain") // not a repository: the mtime dates the file
	w.put(plain+"/audits/a.md", "x\n")
	w.touch(plain+"/audits/a.md", 5*day)
	if got, want := addedEpoch(g, plain, plain+"/audits/a.md", now), w.ago(5*day).Unix(); got != want {
		t.Errorf("a file outside a repository is dated by its mtime: got %d, want %d", got, want)
	}
	if got := addedEpoch(g, plain, plain+"/audits/missing.md", now); got != now {
		t.Errorf("a file that does not exist is dated now: got %d, want %d", got, now)
	}

	repo := w.tgt("repo")
	w.put(repo+"/audits/t.md", "x\n")
	w.commit(repo, 20*day, "add")
	w.put(repo+"/audits/u.md", "x\n")
	w.touch(repo+"/audits/u.md", 2*day)
	w.touch(repo+"/audits/t.md", 0)
	if got, want := addedEpoch(g, repo, repo+"/audits/t.md", now), w.ago(20*day).Unix(); got != want {
		t.Errorf("a tracked file is dated by the commit that added it: got %d, want %d", got, want)
	}
	if got, want := addedEpoch(g, repo, repo+"/audits/u.md", now), w.ago(2*day).Unix(); got != want {
		t.Errorf("an untracked file in a repository is dated by its mtime: got %d, want %d", got, want)
	}
}

func TestAuditSerialAndSort(t *testing.T) {
	r := auditRow{epoch: 42, file: "f", target: "p", claims: "3", status: "pending", age: "1", tag: "T"}
	if got, want := r.serial(), "42\tf\tp\t3\tpending\t1\tT"; got != want {
		t.Errorf("serial = %q, want %q", got, want)
	}
}

func TestSortAuditRows(t *testing.T) {
	row := func(epoch int64, file string) auditRow {
		return auditRow{epoch: epoch, file: file, target: "p", claims: "1", status: "none", age: "0"}
	}
	rows := []auditRow{row(1_800_000_000, "new"), row(946_684_800, "y2k"), row(5, "b"), row(5, "B"), row(5, "a"), row(-3, "neg"), row(5, "_")}
	sortAuditRows(rows)
	var got []string
	for _, r := range rows {
		got = append(got, r.file)
	}
	// 9 digits before 10 (numeric, not lexical), a negative epoch first, equal epochs in byte order of the row.
	if want := "neg,B,_,a,b,y2k,new"; strings.Join(got, ",") != want {
		t.Errorf("order = %s, want %s", strings.Join(got, ","), want)
	}
	sortAuditRows(nil) // an empty queue is fine
}

func TestAuditSkipped(t *testing.T) {
	for _, c := range []struct {
		in    []string
		count int
		names string
	}{
		{nil, 0, ""},
		{[]string{"/a/Honeywell...niagara-help"}, 1, "Honeywell...niagara-help"},
		{[]string{"/a/x...", "/b/y..."}, 2, "x..., y..."},
		{[]string{"/x/my dir.../tail", "/y/z..."}, 3, "my, tail, z..."},
		{[]string{"$RESEARCH_HOME/some/path/..."}, 1, "..."},
	} {
		count, names := auditSkipped(c.in)
		if count != c.count || names != c.names {
			t.Errorf("auditSkipped(%q) = %d, %q; want %d, %q", c.in, count, names, c.count, c.names)
		}
	}
}

func TestAuditClosed(t *testing.T) {
	for s, want := range map[string]bool{"applied": true, "dismissed": true, "": false, "pending": false, "wip": false, "Applied": false, "applied2": false} {
		if got := auditClosed(s); got != want {
			t.Errorf("auditClosed(%q) = %v, want %v", s, got, want)
		}
	}
}

func TestAuditStatusLabel(t *testing.T) {
	if auditStatusLabel("") != "none" || auditStatusLabel("pending") != "pending" || auditStatusLabel("wip") != "wip" {
		t.Error("an absent marker is labelled none; a word is kept")
	}
}

func TestIsDirectory(t *testing.T) {
	w := newWorld(t)
	w.put(w.root+"/file", "x")
	w.must(os.Symlink(w.root, w.root+"/link"))
	w.must(os.Symlink(w.root+"/file", w.root+"/filelink"))
	for p, want := range map[string]bool{w.root: true, w.root + "/link": true, w.root + "/file": false, w.root + "/filelink": false, w.root + "/nope": false} {
		if got := isDirectory(p); got != want {
			t.Errorf("isDirectory(%s) = %v, want %v", strings.TrimPrefix(p, w.root), got, want)
		}
	}
}

func TestAuditStatus(t *testing.T) {
	w := newWorld(t)
	w.put(w.root+"/applied.md", "<!-- review-status: Applied 2026-01-01 -->\n# a\n")
	w.put(w.root+"/none.md", "# a\n<!-- review-status: applied -->\n")
	w.must(os.MkdirAll(w.root+"/dir.md", 0o755))
	for f, want := range map[string]string{"applied.md": "applied", "none.md": "", "dir.md": "", "missing.md": ""} {
		if got := auditStatus(w.root + "/" + f); got != want {
			t.Errorf("auditStatus(%s) = %q, want %q", f, got, want)
		}
	}
	if os.Geteuid() != 0 {
		w.put(w.root+"/locked.md", "<!-- review-status: applied -->\n")
		w.must(os.Chmod(w.root+"/locked.md", 0))
		if got := auditStatus(w.root + "/locked.md"); got != "" {
			t.Errorf("an unreadable audit reads as having no marker, not %q", got)
		}
	}
}

func TestWriteAuditsReport(t *testing.T) {
	const guidance = "For each PENDING audit: apply §14 corrections (REFUTED/DOWNGRADED) into the corpus + seed\n" +
		"coverage gaps into the §8 backlog, then flip the marker to\n" +
		"'<!-- review-status: applied <date> · kit <sha> -->' (or 'dismissed').\n"
	const absentLine = "INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n"
	const warnLine = "WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: x...\n"
	row := auditRow{epoch: 1, file: "/t/audits/a.md", target: "/t", claims: "3", status: "pending", age: "9", tag: "  ·  ESCALATED (aged 9d)"}
	rowText := "PENDING  /t/audits/a.md\n         target: /t  ·  ~3 audited claims  ·  status: pending  ·  age: 9d  ·  ESCALATED (aged 9d)\n"
	for _, c := range []struct {
		name string
		rows []auditRow
		t    auditTotals
		want string
	}{
		{"nothing at all", nil, auditTotals{}, "\nSummary: 0 pending / 0 audits across targets.\nNothing to review.\n"},
		{"all closed", nil, auditTotals{total: 4}, "\nSummary: 0 pending / 4 audits across targets.\nNothing to review.\n"},
		{"absent targets do not suppress the all-clear", nil, auditTotals{absent: 2}, "\nSummary: 0 pending / 0 audits across targets.\n" + absentLine + "Nothing to review.\n"},
		{"a truncated target suppresses it", nil, auditTotals{total: 1, skipped: 1, skippedNames: "x..."}, "\nSummary: 0 pending / 1 audits across targets.\n" + warnLine},
		{"pending audits bring the guidance", []auditRow{row}, auditTotals{pending: 1, total: 2}, rowText + "\nSummary: 1 pending / 2 audits across targets.\n" + guidance},
		{"everything", []auditRow{row}, auditTotals{pending: 1, total: 1, absent: 2, skipped: 1, skippedNames: "x..."},
			rowText + "\nSummary: 1 pending / 1 audits across targets.\n" + absentLine + warnLine + guidance},
	} {
		var b bytes.Buffer
		writeAuditsReport(&b, c.rows, c.t)
		if b.String() != c.want {
			t.Errorf("%s:\ngot:\n%q\nwant:\n%q", c.name, b.String(), c.want)
		}
	}
}

func TestAuditsOperationalExits(t *testing.T) {
	t.Run("--kit without a value is a usage error", func(t *testing.T) {
		w := newWorld(t)
		var o, e bytes.Buffer
		rc := RunAudits([]string{"--kit"}, w.stdio(&o, &e))
		if rc != cli.ExitUsage || o.Len() != 0 || e.String() != "sweep-audits: --kit needs a directory\n" {
			t.Errorf("rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
		}
	})
	t.Run("no kit anywhere", func(t *testing.T) {
		w := newWorld(t)
		var o, e bytes.Buffer
		rc := RunAudits(nil, w.stdio(&o, &e))
		if rc != cli.ExitOperational || o.Len() != 0 || !strings.HasPrefix(e.String(), "sweep-audits: ") || !strings.Contains(e.String(), "kit not found") {
			t.Errorf("rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
		}
	})
	t.Run("the kit of RESEARCH_SDD_KIT", func(t *testing.T) {
		w := newWorld(t)
		a := w.tgt("targetA")
		w.audit(a, "a1.md", auditPending, 1)
		w.targets(a)
		w.put(w.kit+"/toolbelt/sweep-audits.sh", "#!/bin/sh\n")
		w.env["RESEARCH_SDD_KIT"] = w.kit
		var o, e bytes.Buffer
		rc := RunAudits(nil, w.stdio(&o, &e))
		if rc != cli.ExitOK || !strings.Contains(o.String(), "Summary: 1 pending / 1 audits") || e.Len() != 0 {
			t.Errorf("rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
		}
	})
	t.Run("a relative --kit is taken from the working directory", func(t *testing.T) {
		w := newWorld(t)
		a := w.tgt("targetA")
		w.audit(a, "a1.md", auditPending, 1)
		w.targets(a)
		var o, e bytes.Buffer
		rc := RunAudits([]string{"--kit", "kit"}, w.stdio(&o, &e))
		if rc != cli.ExitOK || !strings.Contains(o.String(), "Summary: 1 pending / 1 audits") {
			t.Errorf("rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
		}
	})
	t.Run("TARGETS.md that is a directory", func(t *testing.T) {
		w := newWorld(t)
		w.must(os.MkdirAll(w.kit+"/TARGETS.md", 0o755))
		r := w.runAudits()
		if r.rc != cli.ExitOperational || r.out != "" || r.err != "sweep-audits: cannot find "+w.kit+"/TARGETS.md\n" {
			t.Errorf("%+v", r)
		}
	})
	t.Run("a target that is a file is absent", func(t *testing.T) {
		w := newWorld(t)
		w.put(w.root+"/afile", "x")
		w.targets(w.root + "/afile")
		r := w.runAudits()
		if r.rc != cli.ExitOK || !strings.Contains(r.out, "INFO: corpus not found (absent-input): "+w.root+"/afile\n") ||
			!strings.Contains(r.out, "INFO: 1 target(s) not traversed (absent-input)") {
			t.Errorf("%+v", r)
		}
	})
	t.Run("the report goes to stdout and the diagnostics to stderr", func(t *testing.T) {
		w := newWorld(t)
		w.targets("/no/backticks...")
		r := w.runAudits()
		if r.rc != cli.ExitOperational || r.out != "" || strings.Count(r.err, "\n") != 2 {
			t.Errorf("%+v", r)
		}
	})
}

func TestAuditsEscalationThroughTheReport(t *testing.T) {
	for _, c := range []struct {
		env  string
		want bool
	}{{"", true}, {"7", true}, {"8", false}, {"abc", false}} {
		w := newWorld(t)
		a := w.tgt("targetA")
		w.audit(a, "a1.md", auditPending, 1)
		w.touch(a+"/audits/a1.md", 8*day+time.Hour)
		w.env["RSDD_RETRO_AGE_DAYS"] = c.env
		w.targets(a)
		if got := strings.Contains(w.runAudits().out, "ESCALATED (aged 8d)"); got != c.want {
			t.Errorf("RSDD_RETRO_AGE_DAYS=%q: escalated=%v, want %v", c.env, got, c.want)
		}
	}
}
