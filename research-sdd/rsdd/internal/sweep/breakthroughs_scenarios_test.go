package sweep

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// The behaviour table of `sweep breakthroughs`. Every row is one fixture world and one run; the same rows run
// against the frozen scripts in breakthroughs_diff_test.go (stdout, stderr and exit code of the report and of the
// hook with and without --full must be equal), so an expectation written here is also what the script printed.
// `old` names the case of the pre-port sweep-breakthroughs.test.sh the row replaces (the removed-case map is L4 of
// odd/tasks/sweep-breakthroughs-go.md). golden marks a world made of plain files and directories only (no
// symlink, no mode bit), so it can be recorded in testdata/breakthroughs/golden/cases.txt and replayed without
// bash. nodiff marks a declared difference from the script: the row runs against the Go command only, and says why.

type btScenario struct {
	name   string
	old    string
	setup  func(w *world)
	args   []string
	rc     int
	has    []string // substrings of stdout
	lacks  []string // substrings that stdout must not hold
	errHas []string // substrings of stderr
	hook   []string // substrings of the hook's additionalContext
	golden bool
	nodiff string
}

const (
	btSummaryClean = "Summary: 1 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted · 0 skipped-unreadable.\n"
	btConsistent   = "Ledger consistent — all tagged breakthroughs indexed, no drift.\n"
	btHookHdr      = "Research-SDD breakthrough ledger sweep (§22):\n"
)

// btOne is targetA with one block pfx-block1.md (tagged or not) and the ledger rows built from its path and marker
// line, registered in TARGETS.md.
func btOne(tagged bool, rows func(path string, line int) []string) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		ln := w.block(a, "pfx-block1.md", tagged)
		w.targets(a)
		var r []string
		if rows != nil {
			r = rows(a+"/pfx-block1.md", ln)
		}
		w.btLedger(r...)
	}
}

func indexedRow(path string, line int) []string { return []string{btRow(ptr(path, line))} }

// btText writes a block of the given lines (marker lines among them) and returns nothing.
func (w *world) btText(path string, lines ...string) { w.put(path, strings.Join(lines, "\n")+"\n") }

// btRH is a world whose corpora live under <root>/<rhName> and whose RESEARCH_HOME is that directory spelled by
// spell; the target is registered as `$RESEARCH_HOME/targetA` and the block is indexed by a portable pointer in the
// given form.
func btRH(rhName, spell, form string) func(w *world) {
	return func(w *world) {
		rh := w.root + "/" + rhName
		a := w.tgt(rhName + "/targetA")
		ln := w.block(a, "pfx-block1.md", true)
		if strings.HasPrefix(spell, "unset") {
			delete(w.env, "RESEARCH_HOME")
			w.env["HOME"] = rh + strings.TrimPrefix(spell, "unset")
		} else {
			w.env["RESEARCH_HOME"] = strings.ReplaceAll(spell, "{rh}", rh)
		}
		w.targets("$RESEARCH_HOME/targetA")
		w.btLedger(btRow("`" + form + "/targetA/pfx-block1.md:" + strconv.Itoa(ln) + "`"))
	}
}

func btScenarios() []btScenario {
	return []btScenario{
		{name: "clean tagged and indexed", old: "1, 12, 19, 22", golden: true, setup: btOne(true, indexedRow),
			has: []string{btSummaryClean, btConsistent}, lacks: []string{"WARN"}, hook: []string{btHookHdr + btSummaryClean}},
		{name: "unindexed breakthrough", old: "2, 19", golden: true, setup: btOne(true, nil),
			has:   []string{"WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: {A}/pfx-block1.md:7\n", "1 unindexed", "For each unindexed breakthrough: add a row"},
			lacks: []string{"Ledger consistent"},
			hook:  []string{"WARN: 1 unindexed breakthrough(s) not in BREAKTHROUGHS.md: targetA/pfx-block1.md:7 — add a row each (path:line); run --full for all\n"}},
		{name: "drift marker removed", old: "3", golden: true, setup: btOne(false, func(p string, _ int) []string { return indexedRow(p, 7) }),
			has:   []string{"WARN: drift — indexed block no longer carries the **Breakthrough:** marker: {A}/pfx-block1.md:7 (from BREAKTHROUGHS.md)\n", "1 drifted", "For each drifted row: verify"},
			lacks: []string{"Ledger consistent"}},
		{name: "drift block file gone", old: "4", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "pfx-block9.md", false)
			w.targets(a)
			w.btLedger(btRow(ptr(a+"/gone-block1.md", 7)))
		}, has: []string{"WARN: drift — indexed block file no longer exists: {A}/gone-block1.md (from BREAKTHROUGHS.md)\n", "1 drifted"}},
		{name: "no-match corpus", old: "5", golden: true, setup: btOne(false, nil),
			has:  []string{"INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): {A}\n", "Summary: 0 tagged"},
			hook: []string{"INFO: 1 corpus(es) no-match — run --full to list them\n"}, lacks: []string{"WARN"}},
		{name: "absent corpus", old: "6", golden: true, setup: func(w *world) {
			w.targets(w.root + "/nope")
			w.btLedger()
		}, has: []string{"INFO: corpus not found (absent-input): {root}/nope\n", "INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n"},
			hook: []string{"INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.\n"}, lacks: []string{"empty-input", "no-match"}},
		{name: "empty corpus", old: "7", golden: true, setup: func(w *world) {
			w.tgt("targetA")
			w.targets(w.root + "/targetA")
			w.btLedger()
		}, has: []string{"INFO: corpus exists, no block files (empty-input): {A}\n"}, lacks: []string{"absent-input", "no-match"},
			hook: []string{"INFO: 1 corpus(es) empty-input — run --full to list them\n"}},
		{name: "missing TARGETS.md", old: "8", golden: true, rc: 1, setup: func(w *world) { w.btLedger() },
			errHas: []string{"sweep-breakthroughs: cannot find {kit}/TARGETS.md\n"}, lacks: []string{"Summary:"},
			hook: []string{"Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-breakthroughs: cannot find {kit}/TARGETS.md"}},
		{name: "missing BREAKTHROUGHS.md", old: "9", golden: true, rc: 1, setup: func(w *world) { w.targets(w.tgt("targetA")) },
			errHas: []string{"sweep-breakthroughs: cannot find {kit}/BREAKTHROUGHS.md\n"}, lacks: []string{"Summary:"},
			hook: []string{"could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-breakthroughs: cannot find {kit}/BREAKTHROUGHS.md"}},
		{name: "TARGETS.md is checked before the ledger", old: "8, 9", golden: true, rc: 1, setup: func(w *world) {},
			errHas: []string{"cannot find {kit}/TARGETS.md\n"}, lacks: []string{"BREAKTHROUGHS.md"}},
		{name: "no usable target path", old: "(spot)", golden: true, rc: 1, setup: func(w *world) {
			w.put(w.kit+"/TARGETS.md", "# targets\n\nno table here\n")
			w.btLedger()
		}, errHas: []string{"sweep-breakthroughs: ERROR — no usable target paths in {kit}/TARGETS.md\n", "sweep-breakthroughs: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"}},
		{name: "ledger is checked before the paths", old: "(spot)", golden: true, rc: 1, setup: func(w *world) {
			w.put(w.kit+"/TARGETS.md", "# targets\n")
		}, errHas: []string{"cannot find {kit}/BREAKTHROUGHS.md\n"}, lacks: []string{"no usable"}},
		{name: "two targets one tagged one not", old: "11", golden: true, setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			ln := w.block(a, "pfx-block1.md", true)
			w.block(b, "pfx-block1.md", false)
			w.targets(a, b)
			w.btLedger(btRow(ptr(a+"/pfx-block1.md", ln)))
		}, has: []string{btSummaryClean, "INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): {B}\n"}, lacks: []string{"{A}\n"}},
		{name: "tagged block first of three", old: "13", golden: true, setup: btThree(0), has: []string{btSummaryClean, btConsistent}},
		{name: "tagged block middle of three", old: "15", golden: true, setup: btThree(1), has: []string{btSummaryClean, btConsistent}},
		{name: "tagged block last of three", old: "14", golden: true, setup: btThree(2), has: []string{btSummaryClean, btConsistent}},
		{name: "bare caps prose is not the marker", old: "16", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.btText(a+"/pfx-block1.md", "# Block 1", "", "> BREAKTHROUGH: the pivot", "HITO: the decisive negative", "> note **Breakthrough:** inside", "**Breakthrough:** unquoted")
			w.targets(a)
			w.btLedger()
		}, has: []string{"INFO: no tagged breakthroughs in corpus", "Summary: 0 tagged"}},
		{name: "bloque naming is recognized", old: "17", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "pfx-bloque1.md", true)
			w.targets(a)
			w.btLedger()
		}, has: []string{"WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: {A}/pfx-bloque1.md:7\n"}},
		{name: "files that are not blocks are ignored", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "blocked-notes.md", true)
			w.block(a, "block12.md", true)
			w.block(a, "pfx-block3-extra_name.md", true)
			w.block(a, "pfx-block3.txt", true)
			w.block(a, "sub/dir/deep-block2.md", true)
			w.targets(a)
			w.btLedger()
		}, has: []string{"{A}/pfx-block3-extra_name.md:7\n", "{A}/sub/dir/deep-block2.md:7\n", "Summary: 2 tagged"}, lacks: []string{"blocked-notes", "block12", "pfx-block3.txt"}},
		{name: "two tagged blocks one indexed", old: "18", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			ln := w.block(a, "a-block1.md", true)
			w.block(a, "b-block1.md", true)
			w.targets(a)
			w.btLedger(btRow(ptr(a+"/a-block1.md", ln)))
		}, has: []string{"Summary: 2 tagged breakthrough(s) across corpora · 1 unindexed", "{A}/b-block1.md:7\n"}, lacks: []string{"a-block1.md:7\n"}},
		{name: "skeleton and short rows are skipped", old: "20", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "pfx-block1.md", false)
			w.targets(a)
			w.btLedger("| — | _(no entries yet)_ | | `/nowhere/x-block1.md:3` | |", "| # | h | h | `/nowhere/y-block1.md:3` | |", "| - | h | h | `/nowhere/z-block1.md:3` | |",
				"| | h | h | `/nowhere/e-block1.md:3` | |", "| 1 | only | three |", "|:---|:---|:---|:---|:---|", "no pipe `/nowhere/n-block1.md:3`")
		}, has: []string{"0 drifted"}, lacks: []string{"nowhere", "WARN"}},
		{name: "truncated path is skipped and named", old: "21, 23", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "pfx-block1.md", false)
			w.put(w.kit+"/TARGETS.md", "# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `"+a+"` |\n| 2 | t2 | `$RESEARCH_HOME/some/path/...` |\n")
			w.btLedger()
		}, has: []string{"WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ...\n"}, lacks: []string{"Ledger consistent"}},
		{name: "portable pointer in the only row", old: "24", golden: true, setup: btRH("rh", "{rh}", "$RESEARCH_HOME"), has: []string{btSummaryClean, btConsistent}},
		{name: "portable pointer in the last of two rows", old: "25", golden: true, setup: func(w *world) {
			btRH("rh", "{rh}", "$RESEARCH_HOME")(w)
			w.btLedger(btRow(ptr(w.root+"/elsewhere/x-block1.md", 1)), btRow("`$RESEARCH_HOME/targetA/pfx-block1.md:7`"))
			w.put(w.root+"/elsewhere/x-block1.md", "> **Breakthrough:** x\n")
		}, has: []string{btSummaryClean, btConsistent}},
		{name: "brace form of the portable pointer", old: "26", golden: true, setup: btRH("rh", "{rh}", "${RESEARCH_HOME}"), has: []string{btSummaryClean, btConsistent}},
		{name: "portable pointer is expanded in the drift pass", old: "27", golden: true, setup: func(w *world) {
			btRH("rh", "{rh}", "$RESEARCH_HOME")(w)
			w.btLedger(btRow("`$RESEARCH_HOME/targetA/pfx-block1.md:3`"))
		}, has: []string{"WARN: drift — indexed line does not carry the **Breakthrough:** marker (block still has it elsewhere): {root}/rh/targetA/pfx-block1.md:3 (from BREAKTHROUGHS.md)\n"}},
		{name: "ampersand in RESEARCH_HOME", old: "28, 33", golden: true, setup: btRH("r&d", "{rh}", "$RESEARCH_HOME"), has: []string{btSummaryClean, btConsistent}},
		{name: "trailing slash in RESEARCH_HOME", old: "29, 31", golden: true, setup: btRH("rh", "{rh}/", "$RESEARCH_HOME"), has: []string{btSummaryClean, btConsistent}},
		{name: "RESEARCH_HOME unset falls back to HOME", old: "30", golden: true, setup: btRH("home", "unset", "$RESEARCH_HOME"), has: []string{btSummaryClean, btConsistent}},
		{name: "trailing slash in HOME", old: "32", golden: true, setup: btRH("home", "unset/", "$RESEARCH_HOME"), has: []string{btSummaryClean, btConsistent}},
		{name: "exact line: marker 5 is not pointer 57", old: "34", golden: true, setup: btAt(5, 57),
			has: []string{"WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: {A}/pfx-block1.md:5\n", "WARN: drift — indexed line does not carry"}},
		{name: "exact line: marker 1 is not pointer 10", old: "35", golden: true, setup: btAt(1, 10), has: []string{"{A}/pfx-block1.md:1\n", "1 unindexed"}},
		{name: "exact line: marker 1 pointer 1 is clean", old: "36", golden: true, setup: btAt(1, 1), has: []string{btConsistent}, lacks: []string{"WARN"}},
		{name: "exact line: marker 7 is not pointer 70", old: "37", golden: true, setup: btAt(7, 70), has: []string{"{A}/pfx-block1.md:7\n", "1 unindexed"}},
		{name: "exact line: marker 7 pointer 7 is clean", old: "38", golden: true, setup: btAt(7, 7), has: []string{btConsistent}, lacks: []string{"WARN"}},
		{name: "drift on the pointed line only", old: "39", golden: true, setup: btOne(true, func(p string, _ int) []string { return indexedRow(p, 3) }),
			has: []string{"WARN: drift — indexed line does not carry the **Breakthrough:** marker (block still has it elsewhere): {A}/pfx-block1.md:3 (from BREAKTHROUGHS.md)\n", "1 unindexed", "1 drifted"}},
		{name: "two pointers in one cell", old: "40", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			l1 := w.block(a, "a-block1.md", true)
			l2 := w.block(a, "b-block1.md", true)
			w.targets(a)
			w.btLedger(btRow(ptr(a+"/a-block1.md", l1), ptr(a+"/b-block1.md", l2)))
		}, has: []string{"Summary: 2 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted", btConsistent}},
		{name: "two markers ledger points at the second", old: "41", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.btText(a+"/pfx-block1.md", "# B", "> **Breakthrough:** first", "", "> **Breakthrough:** second")
			w.targets(a)
			w.btLedger(btRow(ptr(a+"/pfx-block1.md", 4)))
		}, has: []string{btSummaryClean, btConsistent}, lacks: []string{"unindexed breakthrough —"}},
		{name: "two markers ledger points at neither", old: "42", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.btText(a+"/pfx-block1.md", "# B", "> **Breakthrough:** first", "", "> **Breakthrough:** second")
			w.targets(a)
			w.btLedger()
		}, has: []string{"Summary: 1 tagged breakthrough(s) across corpora · 1 unindexed", "{A}/pfx-block1.md:2\n"}, lacks: []string{"pfx-block1.md:4"}},
		{name: "unreadable block is skipped loudly", old: "43", golden: true, setup: func(w *world) {
			btOne(true, nil)(w)
			w.unreadable(w.root + "/targetA/pfx-block1.md")
		}, has: []string{"WARN: block file unreadable, marker scan skipped: {A}/pfx-block1.md\n", "Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted · 1 skipped-unreadable.\n"},
			lacks: []string{"Ledger consistent"}, hook: []string{"WARN: block file unreadable, marker scan skipped"}},
		{name: "marker allows blanks after the quote", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.btText(a+"/pfx-block1.md", "#", ">\t **Breakthrough:** tabbed", ">**Breakthrough:** tight")
			w.targets(a)
			w.btLedger()
		}, has: []string{"Summary: 1 tagged breakthrough(s)", "{A}/pfx-block1.md:2\n"}},
		{name: "the hook collapses many lines", old: "(hook 5-13)", golden: true, setup: func(w *world) {
			var ts []string
			for _, n := range []string{"t1", "t2", "t3", "t4", "t5", "t6", "t7"} {
				a := w.tgt(n)
				w.block(a, "x-block1.md", true)
				ts = append(ts, a)
			}
			e1, e2 := w.tgt("e1"), w.tgt("e2")
			w.block(w.tgt("n1"), "x-block1.md", false)
			w.targets(append(ts, e1, e2, w.root+"/n1", w.root+"/gone1", w.root+"/gone2")...)
			w.btLedger()
		}, has: []string{"Summary: 7 tagged breakthrough(s) across corpora · 7 unindexed", "2 target(s)"},
			hook: []string{"WARN: 7 unindexed breakthrough(s) not in BREAKTHROUGHS.md: t1/x-block1.md:7, t2/x-block1.md:7, t3/x-block1.md:7, t4/x-block1.md:7, t5/x-block1.md:7, +2 more — add a row each (path:line); run --full for all\n",
				"INFO: 2 corpus(es) empty-input, 1 no-match — run --full to list them\n"}},

		// Declared differences: the Go command is right, the script was not (tool-registry.d/sweep-breakthroughs.md).
		{name: "unreadable ledger stops the run", old: "(D1)", nodiff: "the script's grep failed silently: every tagged block read as unindexed", rc: 1, setup: func(w *world) {
			btOne(true, indexedRow)(w)
			w.unreadable(w.kit + "/BREAKTHROUGHS.md")
		}, errHas: []string{"sweep-breakthroughs: cannot read {kit}/BREAKTHROUGHS.md\n"}, lacks: []string{"unindexed"},
			hook: []string{"could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-breakthroughs: cannot read "}},
		{name: "symlinked target is traversed", old: "(D2)", nodiff: "the script's find listed the link alone: the corpus read as empty-input", setup: func(w *world) {
			real := w.tgt("real")
			ln := w.block(real, "pfx-block1.md", true)
			w.must(os.Symlink(real, w.root+"/linked"))
			w.targets(w.root + "/linked")
			w.btLedger(btRow(ptr(w.root+"/linked/pfx-block1.md", ln)))
		}, has: []string{btSummaryClean, btConsistent}, lacks: []string{"empty-input"}},
		{name: "zero-padded pointer indexes the block", old: "(D3)", nodiff: "the script compared the pointer text, so file:07 was unindexed while the drift pass passed it",
			setup: btOne(true, func(p string, _ int) []string { return []string{btRow("`" + p + ":07`")} }), has: []string{btSummaryClean, btConsistent}, lacks: []string{"WARN"}},
		{name: "block with a NUL byte is scanned", old: "(D4)", nodiff: "grep printed 'Binary file matches', which the WARN used as a line number", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/pfx-block1.md", "# B\n\x00binary\n> **Breakthrough:** x\n")
			w.targets(a)
			w.btLedger()
		}, has: []string{"WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: {A}/pfx-block1.md:3\n"}},
		{name: "block with invalid UTF-8 is scanned", old: "(D4)", nodiff: "grep treats invalid UTF-8 as binary under a UTF-8 locale", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/pfx-block1.md", "# B\n\xff\xfe latin\n> **Breakthrough:** x\n")
			w.targets(a)
			w.btLedger()
		}, has: []string{"{A}/pfx-block1.md:3\n"}},
		{name: "unreadable pointed file is a typed warning", old: "(D5)", nodiff: "the script reported a file it could not read as a block that lost its marker", setup: func(w *world) {
			a := w.tgt("targetA")
			w.block(a, "other-block1.md", false)
			w.block(w.tgt("elsewhere"), "x-block1.md", true)
			w.targets(a)
			w.btLedger(btRow(ptr(w.root+"/elsewhere/x-block1.md", 7)))
			w.unreadable(w.root + "/elsewhere/x-block1.md")
		}, has: []string{"WARN: drift check skipped — indexed block file unreadable: {root}/elsewhere/x-block1.md:7 (from BREAKTHROUGHS.md)\n", "0 drifted · 1 skipped-unreadable"},
			lacks: []string{"no longer carries", "Ledger consistent"}},
		{name: "pointed file read once as unreadable is counted once", old: "(D5)", nodiff: "the corpus pass and the drift pass see the same unreadable file", setup: func(w *world) {
			a := w.tgt("targetA")
			ln := w.block(a, "pfx-block1.md", true)
			w.targets(a)
			w.btLedger(btRow(ptr(a+"/pfx-block1.md", ln)))
			w.unreadable(a + "/pfx-block1.md")
		}, has: []string{"0 drifted · 1 skipped-unreadable.\n"}},
	}
}

// btThree is targetA with three blocks a, b, c of which only the n-th is tagged and indexed.
func btThree(n int) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		var rows []string
		for i, f := range []string{"a-block1.md", "b-block1.md", "c-block1.md"} {
			if ln := w.block(a, f, i == n); ln > 0 {
				rows = append(rows, btRow(ptr(a+"/"+f, ln)))
			}
		}
		w.targets(a)
		w.btLedger(rows...)
	}
}

// btAt is a block whose only marker sits on line marker, with the ledger pointing at line pointer.
func btAt(marker, pointer int) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		var lines []string
		for i := 1; i <= 9; i++ {
			if i == marker {
				lines = append(lines, "> **Breakthrough:** x")
			} else {
				lines = append(lines, "line")
			}
		}
		w.btText(a+"/pfx-block1.md", lines...)
		w.targets(a)
		w.btLedger(btRow(ptr(a+"/pfx-block1.md", pointer)))
	}
}

func TestBreakthroughsScenarios(t *testing.T) {
	for _, sc := range btScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			sc.setup(w)
			r := w.runBT(sc.args...)
			if r.rc != sc.rc {
				t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, sc.rc, r.out, r.err)
			}
			for _, h := range sc.has {
				if !strings.Contains(r.out, w.expand(h)) {
					t.Errorf("stdout lacks %q\n%s", h, r.out)
				}
			}
			for _, l := range sc.lacks {
				if strings.Contains(r.out, w.expand(l)) || strings.Contains(r.err, w.expand(l)) {
					t.Errorf("output holds %q\n%s\n%s", l, r.out, r.err)
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
			hr := w.runBTHook(sc.args...)
			ctx := decodeHookCtx(t, hr.out)
			if hr.rc != 0 || hr.err != "" || ctx == "" {
				t.Errorf("a hook exits 0, speaks, and has an empty stderr: %+v", hr)
			}
			for _, h := range sc.hook {
				if !strings.Contains(ctx+"\n", w.expand(h)) {
					t.Errorf("hook context lacks %q\n%s", h, ctx)
				}
			}
		})
	}
}
