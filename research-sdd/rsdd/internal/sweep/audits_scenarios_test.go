package sweep

import (
	"os"
	"strings"
	"testing"
	"time"
)

// The behaviour table of `sweep audits`. Every row is one fixture world and one run; the same rows run against
// the frozen scripts in audits_diff_test.go (stdout, stderr and exit code of the report, the hook and the hook
// --full must be equal), so an expectation written here is also what the script printed. `old` names the case of
// the pre-port sweep-audits.test.sh the row replaces (the removed-case map is L3 of odd/tasks/sweep-audits-go.md).
// golden marks a world made of plain files and directories only (no git, symlink or permission), so it can be
// recorded in testdata/audits/golden/cases.txt and replayed without bash.

type auditScenario struct {
	name   string
	old    string
	setup  func(w *world)
	args   []string
	rc     int
	has    []string // substrings of stdout
	lacks  []string // substrings that stdout must not hold
	errHas []string // substrings of stderr
	golden bool
}

const (
	auditPending = "<!-- review-status: pending -->"
	auditApplied = "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
)

// oneAudit is one audit in targetA, registered.
func oneAudit(marker string, n int) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.audit(a, "a1.md", marker, n)
		w.targets(a)
	}
}

// bodyAudit is one audit with the given full text in targetA, registered.
func bodyAudit(text string) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.put(a+"/audits/a1.md", text)
		w.targets(a)
	}
}

// renamedAudit makes an audit created 20 years ago and renamed a year later (the rename is the accepted dating).
func renamedAudit(renames string) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.audit(a, "orig.md", auditPending, 1)
		w.commit(a, 20*365*day, "add orig")
		w.git(a, nil, "config", "diff.renames", renames)
		w.git(a, nil, "mv", "audits/orig.md", "audits/renamed.md")
		w.commit(a, 2*day, "rename")
		w.targets(a)
	}
}

func auditScenarios() []auditScenario {
	return []auditScenario{
		{name: "pending marker is surfaced", old: "1", setup: oneAudit(auditPending, 3), golden: true,
			has: []string{"PENDING", "a1.md", "status: pending", "~3 audited claims", "Summary: 1 pending / 1 audits across targets."}},
		{name: "applied marker is not pending", old: "2", setup: oneAudit(auditApplied, 4), golden: true,
			has: []string{"Summary: 0 pending / 1 audits", "Nothing to review."}, lacks: []string{"PENDING", "For each PENDING audit"}},
		{name: "dismissed marker is not pending", old: "(spot)", setup: oneAudit("<!-- review-status: dismissed 2026-01-01 -->", 2), golden: true,
			has: []string{"Summary: 0 pending / 1 audits"}, lacks: []string{"PENDING"}},
		{name: "absent marker is pending with status none", old: "3", setup: oneAudit("", 2), golden: true,
			has: []string{"PENDING", "status: none", "~2 audited claims"}},
		{name: "unknown status word stays pending", old: "(spot)", setup: oneAudit("<!-- review-status: wip -->", 1), golden: true,
			has: []string{"status: wip"}},
		{name: "status word is lowercased", old: "(spot)", setup: oneAudit("<!-- review-status: APPLIED -->", 1), golden: true,
			has: []string{"Summary: 0 pending / 1 audits"}},
		{name: "marker after the first heading is no marker", old: "(spot)", setup: bodyAudit("# audit\n<!-- review-status: applied -->\n| 1 | c | v |\n"), golden: true,
			has: []string{"PENDING", "status: none", "~1 audited claims"}},
		{name: "BOM and CRLF marker", old: "(spot)", setup: bodyAudit("\xef\xbb\xbf<!-- review-status: applied -->\r\n# audit\r\n| 1 | c | v |\r\n"), golden: true,
			has: []string{"Summary: 0 pending / 1 audits"}},
		{name: "multi-target totals", old: "4", golden: true, setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.audit(a, "p.md", auditPending, 2)
			w.audit(a, "done.md", "<!-- review-status: applied 2026-01-01 -->", 5)
			w.audit(b, "p.md", auditPending, 1)
			w.targets(a, b)
		}, has: []string{"Summary: 2 pending / 3 audits"}},
		{name: "truncated path is skipped and named", old: "5", golden: true, setup: func(w *world) {
			a, dots := w.tgt("targetA"), w.tgt("Honeywell...niagara-help")
			w.audit(a, "a1.md", auditPending, 1)
			w.audit(dots, "a1.md", auditPending, 1)
			w.targets(a, dots)
		}, has: []string{"Summary: 1 pending / 1 audits", "WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: Honeywell...niagara-help"}},
		{name: "no truncated path no WARN", old: "6", setup: oneAudit(auditPending, 1), golden: true,
			lacks: []string{"WARN:", "PARTIAL"}},
		{name: "missing TARGETS.md", old: "7", setup: func(w *world) {}, rc: 1, golden: true,
			errHas: []string{"sweep-audits: cannot find {kit}/TARGETS.md\n"}, lacks: []string{"Summary:"}},
		{name: "aged audit is escalated and sorted first", old: "8", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "fresh.md", auditPending, 1)
			w.audit(a, "old.md", auditPending, 1)
			w.touch(a+"/audits/old.md", 3*day)
			w.env["RSDD_RETRO_AGE_DAYS"] = "1"
			w.targets(a)
		}, has: []string{"audits/old.md\n         target: {A}  ·  ~1 audited claims  ·  status: pending  ·  age: 3d  ·  ESCALATED (aged 3d)\nPENDING  {A}/audits/fresh.md\n"}},
		{name: "nested research/audits is listed and aged", old: "9", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a+"/research", "n1.md", auditPending, 3)
			w.touch(a+"/research/audits/n1.md", deepPast)
			w.env["RSDD_RETRO_AGE_DAYS"] = "1"
			w.targets(a)
		}, has: []string{"PENDING  {A}/research/audits/n1.md", "~3 audited claims", "Summary: 1 pending / 1 audits", "ESCALATED (aged "}},
		{name: "index files are not audits", old: "10", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 2)
			w.put(a+"/audits/AUDITS-INDEX.md", "# Audits index\n\n| # | file |\n|---|---|\n| 1 | a1.md |\n")
			w.put(a+"/audits/my-Index-notes.md", "# index\n")
			w.targets(a)
		}, has: []string{"a1.md", "Summary: 1 pending / 1 audits"}, lacks: []string{"INDEX", "Index"}},
		{name: "RESEARCH_HOME form resolves", old: "12", golden: true, setup: func(w *world) {
			base := w.tgt("rh_base")
			w.audit(base+"/rh_audit_target", "a1.md", auditPending, 2)
			w.env["RESEARCH_HOME"] = base
			w.targets("$RESEARCH_HOME/rh_audit_target")
		}, has: []string{"PENDING", "Summary: 1 pending / 1 audits"}},
		{name: "no usable path", old: "13", golden: true, setup: func(w *world) {
			w.put(w.kit+"/TARGETS.md", "# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n")
		}, rc: 1, errHas: []string{"sweep-audits: ERROR — no usable target paths in {kit}/TARGETS.md\n", "sweep-audits: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
			lacks: []string{"Summary:"}},
		{name: "renamed audit is dated from the rename", old: "14", setup: renamedAudit("false"),
			has: []string{"PENDING", "age: 2d\n"}, lacks: []string{"ESCALATED"}},
		{name: "renamed audit with diff.renames true", old: "14b", setup: renamedAudit("true"),
			has: []string{"PENDING", "age: 2d\n"}, lacks: []string{"ESCALATED"}},
		{name: "partial sweep with nothing pending", old: "15", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", "<!-- review-status: applied 2026-01-01 -->", 2)
			w.targets(a, "$RESEARCH_HOME/some/path/...")
		}, has: []string{"WARN: 1 target(s) skipped", "Summary: 0 pending / 1 audits"}, lacks: []string{"Nothing to review."}},
		{name: "clean sweep says nothing to review", old: "16", setup: oneAudit("<!-- review-status: applied 2026-01-01 -->", 2), golden: true,
			has: []string{"Nothing to review."}, lacks: []string{"PARTIAL"}},
		{name: "absent target is disclosed", old: "17", golden: true, setup: func(w *world) {
			a := w.tgt("presentTarget")
			w.audit(a, "a1.md", auditPending, 2)
			w.targets(a, w.root+"/nonexistent-dir")
		}, has: []string{"INFO: corpus not found (absent-input): {root}/nonexistent-dir\n", "PENDING", "Summary: 1 pending / 1 audits",
			"INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n"}},
		{name: "corpus without audits is disclosed", old: "18", golden: true, setup: func(w *world) {
			a, e := w.tgt("targetA"), w.tgt("emptyCorpus")
			w.audit(a, "a1.md", auditPending, 2)
			w.targets(a, e)
		}, has: []string{"INFO: corpus exists, no audits found (empty-input): {root}/emptyCorpus\n", "Summary: 1 pending / 1 audits"}},
		{name: "absent target and nothing pending", old: "19", golden: true, setup: func(w *world) {
			w.targets(w.root + "/nonexistent-only")
		}, has: []string{"INFO: corpus not found (absent-input)", "Nothing to review."}, lacks: []string{"For each PENDING audit"}},
		{name: "guidance only with pending audits", old: "19, teeth", golden: true, setup: oneAudit(auditPending, 1),
			has:   []string{"For each PENDING audit: apply §14 corrections (REFUTED/DOWNGRADED) into the corpus + seed\ncoverage gaps into the §8 backlog, then flip the marker to\n'<!-- review-status: applied <date> · kit <sha> -->' (or 'dismissed').\n"},
			lacks: []string{"Nothing to review."}},
		{name: "claims are rows that open with | n |", old: "(spot)", golden: true, setup: bodyAudit(auditPending + "\n# audit\n| 1 | a | b |\n|2| no | b |\n| 3  | no | b |\n|  4 | no | b |\n  | 5 | no | b |\n| x | no | b |\n| 12 | yes | b |\n|---|---|---|\n"),
			has: []string{"~3 audited claims"}},
		{name: "last line without newline counts", old: "(spot)", golden: true, setup: bodyAudit(auditPending + "\n| 1 | a | b |\n| 2 | a | b |"),
			has: []string{"~2 audited claims"}},
		{name: "audits dir at depth four is read, depth five is not", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a+"/x/y", "d4.md", auditPending, 1)
			w.audit(a+"/x/y/z", "d5.md", auditPending, 1)
			w.targets(a)
		}, has: []string{"audits/d4.md", "Summary: 1 pending / 1 audits"}, lacks: []string{"d5.md"}},
		{name: "git directory is not walked", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.audit(a+"/.git", "hidden.md", auditPending, 1)
			w.targets(a)
		}, has: []string{"Summary: 1 pending / 1 audits"}, lacks: []string{"hidden.md"}},
		{name: "non-markdown files are not audits", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.put(a+"/audits/notes.txt", "x\n")
			w.put(a+"/audits/.md", auditText(auditApplied, 1))
			w.put(a+"/audits/sub/dir/deep.md", auditText("", 1))
			w.targets(a)
		}, has: []string{"Summary: 2 pending / 3 audits"}},
		{name: "retros are not audits", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/r1.md", retroText(pendingMarker, 1))
			w.targets(a)
		}, has: []string{"INFO: corpus exists, no audits found (empty-input): {A}\n", "Summary: 0 pending / 0 audits"}},
		{name: "tied ages sort by row", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			for _, n := range []string{"b.md", "B.md", "a.md", "_.md", "1.md"} {
				w.audit(a, n, auditPending, 1)
				w.touch(a+"/audits/"+n, 3*day)
			}
			w.targets(a)
		}, has: []string{"PENDING  {A}/audits/1.md\n", "Summary: 5 pending / 5 audits"}},
		{name: "age threshold zero escalates a day-old audit", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.touch(a+"/audits/a1.md", 2*day)
			w.env["RSDD_RETRO_AGE_DAYS"] = "0"
			w.targets(a)
		}, has: []string{"age: 2d  ·  ESCALATED (aged 2d)"}},
		{name: "age equal to the threshold is not escalated", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.touch(a+"/audits/a1.md", 2*day+time.Hour)
			w.env["RSDD_RETRO_AGE_DAYS"] = "2"
			w.targets(a)
		}, has: []string{"age: 2d\n"}, lacks: []string{"ESCALATED"}},
		{name: "default threshold is seven days", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a.md", auditPending, 1)
			w.audit(a, "b.md", auditPending, 1)
			w.touch(a+"/audits/a.md", 7*day+time.Hour)
			w.touch(a+"/audits/b.md", 8*day+time.Hour)
			w.targets(a)
		}, has: []string{"age: 7d\n", "age: 8d  ·  ESCALATED (aged 8d)"}},
		{name: "non-numeric threshold never escalates", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.touch(a+"/audits/a1.md", deepPast)
			w.env["RSDD_RETRO_AGE_DAYS"] = "abc"
			w.targets(a)
		}, lacks: []string{"ESCALATED"}},
		{name: "empty threshold is the default", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.touch(a+"/audits/a1.md", 8*day+time.Hour)
			w.env["RSDD_RETRO_AGE_DAYS"] = ""
			w.targets(a)
		}, has: []string{"ESCALATED (aged 8d)"}},
		{name: "negative threshold escalates a fresh audit", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.env["RSDD_RETRO_AGE_DAYS"] = "-1"
			w.targets(a)
		}, has: []string{"age: 0d  ·  ESCALATED (aged 0d)"}},
		{name: "a future mtime ages zero days", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.must(os.Chtimes(a+"/audits/a1.md", w.now.Add(30*day), w.now.Add(30*day)))
			w.targets(a)
		}, has: []string{"age: 0d\n"}},
		{name: "a git-tracked audit is dated from its commit", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.commit(a, 20*day, "add")
			w.touch(a+"/audits/a1.md", 0)
			w.targets(a)
		}, has: []string{"age: 20d  ·  ESCALATED (aged 20d)"}},
		{name: "an audit untracked in a repository is dated by mtime", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "tracked.md", auditPending, 1)
			w.commit(a, 20*day, "add")
			w.audit(a, "new.md", auditPending, 1)
			w.touch(a+"/audits/new.md", 2*day)
			w.targets(a)
		}, has: []string{"audits/new.md\n         target: {A}  ·  ~1 audited claims  ·  status: pending  ·  age: 2d\n"}},
		{name: "directory named like an audit", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.must(os.MkdirAll(a+"/audits/odd.md", 0o755))
			w.targets(a)
		}},
		{name: "unreadable audit", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.must(os.Chmod(a+"/audits/a1.md", 0))
			w.targets(a)
		}, has: []string{"status: none", "~? audited claims"}},
		{name: "symlinked audit counts once", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.must(os.Symlink(a+"/audits/a1.md", a+"/audits/link.md"))
			w.must(os.Symlink(a+"/audits", a+"/linkdir"))
			w.targets(a)
		}, has: []string{"Summary: 1 pending / 1 audits"}},
		{name: "symlink to a directory holds no audit", old: "(spot)", setup: func(w *world) {
			real := w.tgt("real")
			w.audit(real, "a1.md", auditPending, 1)
			link := w.root + "/link"
			w.must(os.Symlink(real, link))
			w.targets(link, real)
		}, has: []string{"INFO: corpus exists, no audits found (empty-input): {root}/link\n", "Summary: 1 pending / 1 audits"}},
		{name: "overlapping targets count an audit once", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a+"/sub", "a1.md", auditPending, 2)
			w.audit(a, "a0.md", "", 1)
			w.targets(a, a+"/sub", a)
		}, has: []string{"Summary: 2 pending / 2 audits"}},
		{name: "trailing slash target", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.targets(a + "/")
		}, has: []string{"Summary: 1 pending / 1 audits"}},
		{name: "target path with a space is split into words", old: "(spot)", setup: func(w *world) {
			a := w.tgt("my target")
			w.audit(a, "a1.md", auditPending, 1)
			w.targets(a)
		}, has: []string{"INFO: corpus not found (absent-input): {root}/my\n", "INFO: corpus not found (absent-input): target\n"}},
		{name: "truncated path with a space", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.audit(a, "a1.md", auditPending, 1)
			w.targets(a, "/x/my dir.../tail", "/y/z...")
		}, has: []string{"WARN: 3 target(s) skipped", "PARTIAL: my, tail, z..."}},
		{name: "audits path inside the target prefix", old: "(spot)", setup: func(w *world) {
			a := w.tgt("audits/targetA")
			w.put(a+"/note.md", auditText("", 1))
			w.targets(a)
		}, has: []string{"PENDING  {root}/audits/targetA/note.md"}},
		{name: "unknown arguments are ignored", old: "(script ignored them)", setup: oneAudit(auditPending, 1), args: []string{"--nope", "extra"},
			has: []string{"Summary: 1 pending / 1 audits"}},
	}
}

func TestAuditsScenarios(t *testing.T) {
	for _, sc := range auditScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			sc.setup(w)
			r := w.runAudits(sc.args...)
			if r.rc != sc.rc {
				t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, sc.rc, r.out, r.err)
			}
			for _, h := range sc.has {
				if !strings.Contains(r.out, w.expand(h)) {
					t.Errorf("stdout lacks %q\n%s", h, r.out)
				}
			}
			for _, l := range sc.lacks {
				if strings.Contains(r.out, w.expand(l)) {
					t.Errorf("stdout holds %q\n%s", l, r.out)
				}
			}
			for _, h := range sc.errHas {
				if !strings.Contains(r.err, w.expand(h)) {
					t.Errorf("stderr lacks %q\n%s", h, r.err)
				}
			}
			if sc.rc == 0 && r.err != "" {
				t.Errorf("unexpected stderr: %q", r.err)
			}
		})
	}
}
