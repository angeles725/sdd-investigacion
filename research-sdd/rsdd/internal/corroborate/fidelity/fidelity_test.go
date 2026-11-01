package fidelity

// Old tooth (tests/java-fidelity-experiment.test.sh, sed mutants A-L) -> the Go test that now pins it.
// The bash mutants edited the text of the script and cannot apply to the shim; each guard is pinned here and was
// mutation-checked by hand (one mutant per guard turns `go test` red).
//
//	A  comparison always equal (DIVERGED reported GOOD)     TestFullRun (Diff cells), TestCellOutcomes/diverged
//	B  recompile status ignored                             TestFullRun (Broken cells), TestCellOutcomes/recompile
//	C  empty decompiler output not detected                 TestFullRun (Empty cells), TestCellOutcomes/no-output
//	D  javac probe disabled                                 TestProbes/javac override missing, TestProbes/javac not on PATH
//	E  decompiler rc 3 treated as an ordinary failure       TestDecompilerMissingMidRun
//	F  empty fixtures dir exits 0                           TestFixturesStates/empty
//	G  -g flag dropped from the debug-info probe            TestFlagsPerMode, TestFullRun (Dbg DEBUGINFO)
//	H  unmeasured guard removed                             TestFullRun (Nocompile DEBUGINFO), TestLVTUnmeasured
//	I  timeout status 124 not typed                         TestCellOutcomes/timeout, TestDecompilerBound, TestProcRunner
//	J  fallback attribution dropped                         TestFullRun (Dbg FALLBACK), TestCellOutcomes/fallback-unknown-engine
//	K  executable-bit-only probe (directory as javac)       TestProbes/javac override is a directory
//	L  timeout env validation dropped                       TestTimeoutValidation

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fullWorld(t *testing.T) *world {
	t.Helper()
	w := newWorld(t)
	w.fixture("Same", "public class Same { return a + 1; }")
	w.decs["Same"] = copyDec(okOut, 0)
	w.fixture("Diff", "public class Diff { return a + 1; }")
	w.decs["Diff"] = decBehavior{out: okOut, files: map[string]string{"@name.java": "public class Diff { return a + 2; }"}}
	w.fixture("Broken", "public class Broken { return a; }")
	w.decs["Broken"] = decBehavior{out: okOut, files: map[string]string{"@name.java": "class Broken { SYNTAX }"}}
	w.fixture("Gone", "public class Gone { return a; }")
	w.decs["Gone"] = decBehavior{rc: 1, out: "boom\n"}
	w.fixture("Empty", "public class Empty { return a; }")
	w.decs["Empty"] = decBehavior{out: okOut}
	w.fixture("Multi", "public class Multi { INNER return a; }")
	w.decs["Multi"] = copyDec(okOut, 0)
	w.fixture("Hang", "public class Hang { return a; }")
	w.decs["Hang"] = decBehavior{rc: 124}
	w.fixture("Nocompile", "public class Nocompile { SYNTAX }")
	w.fixture("Dbg", "public class Dbg { int b = a + 1; }")
	w.decs["Dbg"] = copyDec("DEGRADED: in -> out  (engine=stub units=1 primary=error)\nUNIT: Dbg reason=error fallback=cfr result=ok\n", 4)
	return w
}

const fullWant = `FIDELITY Broken mode=g verdict=FAILED reason=recompile
FIDELITY Broken mode=nog verdict=FAILED reason=recompile
DEBUGINFO Broken g_lvt=yes nog_lvt=no
FALLBACK Dbg mode=g labelled-engine=stub
FIDELITY Dbg mode=g verdict=GOOD
FALLBACK Dbg mode=nog labelled-engine=stub
FIDELITY Dbg mode=nog verdict=GOOD
DEBUGINFO Dbg g_lvt=yes nog_lvt=no
FIDELITY Diff mode=g verdict=DIVERGED
FIDELITY Diff mode=nog verdict=DIVERGED
DEBUGINFO Diff g_lvt=yes nog_lvt=no
FIDELITY Empty mode=g verdict=FAILED reason=no-output
FIDELITY Empty mode=nog verdict=FAILED reason=no-output
DEBUGINFO Empty g_lvt=yes nog_lvt=no
FIDELITY Gone mode=g verdict=FAILED reason=decompile
FIDELITY Gone mode=nog verdict=FAILED reason=decompile
DEBUGINFO Gone g_lvt=yes nog_lvt=no
FIDELITY Hang mode=g verdict=FAILED reason=timeout
FIDELITY Hang mode=nog verdict=FAILED reason=timeout
DEBUGINFO Hang g_lvt=yes nog_lvt=no
FIDELITY Multi mode=g verdict=FAILED reason=multi-class
FIDELITY Multi mode=nog verdict=FAILED reason=multi-class
DEBUGINFO Multi g_lvt=yes nog_lvt=no
FIDELITY Nocompile mode=g verdict=FAILED reason=compile
FIDELITY Nocompile mode=nog verdict=FAILED reason=compile
DEBUGINFO Nocompile g_lvt=unmeasured nog_lvt=unmeasured
FIDELITY Same mode=g verdict=GOOD
FIDELITY Same mode=nog verdict=GOOD
DEBUGINFO Same g_lvt=yes nog_lvt=no
RESULT: DONE jdk=21.0.1 engines=stub engine_degraded_cells=2 constructs=9 cells=18 good=4 diverged=2 failed=12
`

// TestFullRun is the nine-fixture stub run of the bash suite (cases 1-17), byte for byte.
func TestFullRun(t *testing.T) {
	w := fullWorld(t)
	out, errs, rc := w.exec(w.args(), "RSDD_FIDELITY_TIMEOUT=2")
	if rc != 0 || errs != "" {
		t.Fatalf("rc=%d stderr=%q", rc, errs)
	}
	if out != fullWant {
		t.Fatalf("stdout differs:\n--- got\n%s--- want\n%s", out, fullWant)
	}
}

// TestCellOutcomes drives one fixture through every typed outcome of a cell.
func TestCellOutcomes(t *testing.T) {
	src := "public class X { return a; }"
	good := map[string]string{"@name.java": "@orig"}
	cases := []struct {
		name  string
		setup func(w *world)
		dec   decBehavior
		want  string // the g-mode FIDELITY line, plus the optional FALLBACK line before it
		rc    int
	}{
		{"good", nil, copyDec(okOut, 0), "FIDELITY X mode=g verdict=GOOD\n", 0},
		{"diverged", nil, decBehavior{out: okOut, files: map[string]string{"@name.java": "public class X { return a + 9; }"}}, "FIDELITY X mode=g verdict=DIVERGED\n", 0},
		{"recompile", nil, decBehavior{out: okOut, files: map[string]string{"@name.java": "SYNTAX"}}, "FIDELITY X mode=g verdict=FAILED reason=recompile\n", 0},
		{"no-output", nil, decBehavior{out: okOut}, "FIDELITY X mode=g verdict=FAILED reason=no-output\n", 0},
		{"multi-output", nil, decBehavior{out: okOut, files: map[string]string{"X.java": "@orig", "Y.java": "@orig"}}, "FIDELITY X mode=g verdict=FAILED reason=multi-output\n", 0},
		{"recompile-no-class", nil, decBehavior{out: okOut, files: map[string]string{"Other.java": "@orig"}}, "FIDELITY X mode=g verdict=FAILED reason=recompile-no-class\n", 0},
		{"decompile rc1", nil, decBehavior{rc: 1, out: "boom\n"}, "FIDELITY X mode=g verdict=FAILED reason=decompile\n", 0},
		{"decompile rc2", nil, decBehavior{rc: 2, files: good}, "FIDELITY X mode=g verdict=FAILED reason=decompile\n", 0},
		{"decompile rc5", nil, decBehavior{rc: 5, files: good}, "FIDELITY X mode=g verdict=FAILED reason=decompile\n", 0},
		{"decompile rc127", nil, decBehavior{rc: 127}, "FIDELITY X mode=g verdict=FAILED reason=decompile\n", 0},
		{"decompile rc125", nil, decBehavior{rc: 125, files: good}, "FIDELITY X mode=g verdict=FAILED reason=decompile\n", 0},
		{"timeout", nil, decBehavior{rc: 124, files: good}, "FIDELITY X mode=g verdict=FAILED reason=timeout\n", 0},
		{"fallback", nil, copyDec("DEGRADED: x (engine=vf units=1)\n", 4), "FALLBACK X mode=g labelled-engine=vf\nFIDELITY X mode=g verdict=GOOD\n", 0},
		{"fallback-unknown-engine", nil, copyDec("DEGRADED: x without an engine label\n", 4), "FALLBACK X mode=g labelled-engine=unknown\nFIDELITY X mode=g verdict=GOOD\n", 0},
		{"fallback-empty-engine", nil, copyDec("DEGRADED: x (engine= units=1)\n", 4), "FALLBACK X mode=g labelled-engine=unknown\nFIDELITY X mode=g verdict=GOOD\n", 0},
		{"fallback-then-diverged", nil, decBehavior{rc: 4, out: "(engine=a )\n", files: map[string]string{"@name.java": "public class X { }"}}, "FALLBACK X mode=g labelled-engine=a\nFIDELITY X mode=g verdict=DIVERGED\n", 0},
		{"fallback-no-output", nil, decBehavior{rc: 4, out: "(engine=a)\n"}, "FALLBACK X mode=g labelled-engine=a\nFIDELITY X mode=g verdict=FAILED reason=no-output\n", 0},
		{"javap-original", func(w *world) { w.fixture("X", "public class X { JAVAPFAIL }") }, copyDec(okOut, 0), "FIDELITY X mode=g verdict=FAILED reason=javap-original\n", 0},
		{"javap-recompiled", nil, decBehavior{out: okOut, files: map[string]string{"@name.java": "public class X { JAVAPFAIL }"}}, "FIDELITY X mode=g verdict=FAILED reason=javap-recompiled\n", 0},
		{"compile", func(w *world) { w.fixture("X", "SYNTAX") }, copyDec(okOut, 0), "FIDELITY X mode=g verdict=FAILED reason=compile\n", 0},
		{"suffix-class-ignored", nil, decBehavior{out: okOut, files: map[string]string{"@name.java": "public class X { PRE }"}}, "FIDELITY X mode=g verdict=DIVERGED\n", 0},
		{"duplicate-class-name", nil, decBehavior{out: okOut, files: map[string]string{"@name.java": "public class X { DUP }"}}, "FIDELITY X mode=g verdict=FAILED reason=javap-recompiled\n", 0},
		{"no-class", func(w *world) { w.fixture("X", "NOCLASS") }, copyDec(okOut, 0), "FIDELITY X mode=g verdict=FAILED reason=multi-class\n", 0},
		{"multi-class", func(w *world) { w.fixture("X", "INNER") }, copyDec(okOut, 0), "FIDELITY X mode=g verdict=FAILED reason=multi-class\n", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.fixture("X", src)
			if c.setup != nil {
				c.setup(w)
			}
			w.decs["X"] = c.dec
			out, _, rc := w.exec(w.args())
			if rc != c.rc {
				t.Fatalf("rc=%d\n%s", rc, out)
			}
			if !strings.HasPrefix(out, c.want) {
				t.Fatalf("stdout does not start with %q:\n%s", c.want, out)
			}
		})
	}
}

// TestRecompileFailureFlagsOnlyItsMode: a verdict is per cell, and the tally counts every cell exactly once.
func TestSummaryTally(t *testing.T) {
	w := newWorld(t)
	w.fixture("A", "class A { 1 }")
	w.decs["A"] = copyDec(okOut, 0)
	w.fixture("B", "class B { 2 }")
	w.decs["B"] = decBehavior{out: okOut, files: map[string]string{"@name.java": "class B { 3 }"}}
	w.fixture("C", "class C { 4 }")
	w.decs["C"] = decBehavior{rc: 1}
	out, _, _ := w.exec(w.args())
	want := "RESULT: DONE jdk=21.0.1 engines=stub engine_degraded_cells=0 constructs=3 cells=6 good=2 diverged=2 failed=2\n"
	if !strings.HasSuffix(out, want) {
		t.Fatalf("summary line:\n%s", out)
	}
}

// TestEnginesAreDeduplicatedInOrder pins the engines= list: first-seen order, no repeats, "unknown" when empty.
func TestEnginesList(t *testing.T) {
	w := newWorld(t)
	w.fixture("A", "class A { 1 }")
	w.decs["A"] = copyDec("OK (engine=zeta)\n", 0)
	w.fixture("B", "class B { 2 }")
	w.decs["B"] = copyDec("OK (engine=alpha)\n", 0)
	w.fixture("C", "class C { 3 }")
	w.decs["C"] = copyDec("OK (engine=zeta)\n", 0)
	out, _, _ := w.exec(w.args())
	if !strings.Contains(out, " engines=zeta,alpha ") {
		t.Fatalf("engines list:\n%s", out)
	}
	w2 := newWorld(t)
	w2.fixture("A", "class A { 1 }")
	w2.decs["A"] = decBehavior{rc: 1}
	out, _, _ = w2.exec(w2.args())
	if !strings.Contains(out, " engines=unknown ") {
		t.Fatalf("no engine seen must read unknown:\n%s", out)
	}
}

// TestFlagsPerMode: g mode compiles and recompiles with -g, nog with no flag at all (tooth G).
func TestFlagsPerMode(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "public class X { return a; }")
	w.decs["X"] = copyDec(okOut, 0)
	w.exec(w.args())
	var g, nog int
	for _, c := range w.callsTo(w.javac) {
		if len(c.Argv) == 2 { // -version
			continue
		}
		switch {
		case c.Argv[1] == "-g":
			g++
			if len(c.Argv) != 5 || c.Argv[2] != "-d" {
				t.Errorf("g argv %q", c.Argv)
			}
		case c.Argv[1] == "-d":
			nog++
			if len(c.Argv) != 4 {
				t.Errorf("nog argv %q", c.Argv)
			}
		default:
			t.Errorf("unexpected javac argv %q", c.Argv)
		}
	}
	if g != 2 || nog != 2 { // one compile and one recompile per mode
		t.Fatalf("g=%d nog=%d, want 2 and 2", g, nog)
	}
}

// TestLVTUnmeasured: no class, or a javap -l failure, reads unmeasured and never "no" (tooth H).
func TestLVTUnmeasured(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "public class X { LVTFAIL }")
	w.decs["X"] = copyDec(okOut, 0)
	out, _, _ := w.exec(w.args())
	if !strings.Contains(out, "DEBUGINFO X g_lvt=unmeasured nog_lvt=unmeasured\n") {
		t.Fatalf("javap -l failure must read unmeasured:\n%s", out)
	}
	if !strings.Contains(out, "FIDELITY X mode=g verdict=GOOD\n") {
		t.Fatalf("a failing -l probe must not change the cell verdict:\n%s", out)
	}
}

// TestLVTSeveralClasses: one LocalVariableTable anywhere in the class set reads yes, and every class is probed.
func TestLVTSeveralClasses(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "public class X { INNER }")
	w.decs["X"] = copyDec(okOut, 0)
	w.exec(w.args())
	probes := 0
	for _, c := range w.callsTo(w.javap) {
		if c.Argv[1] == "-l" {
			probes++
		}
	}
	if probes != 4 { // two classes in each of the two modes
		t.Fatalf("javap -l probes = %d, want 4", probes)
	}
}

// TestDecompilerMissingMidRun: wrapper rc 3 is a typed DEGRADED with the cells already measured named, never DONE (tooth E).
func TestDecompilerMissingMidRun(t *testing.T) {
	w := newWorld(t)
	w.fixture("A", "class A { 1 }")
	w.decs["A"] = copyDec(okOut, 0)
	w.fixture("B", "class B { 2 }")
	w.decs["B"] = decBehavior{rc: 3, out: "no engine\n"}
	out, errs, rc := w.exec(w.args())
	want := "FIDELITY A mode=g verdict=GOOD\nFIDELITY A mode=nog verdict=GOOD\nDEBUGINFO A g_lvt=yes nog_lvt=no\n" +
		"DEGRADED: reason=decompiler-missing (decompiler exit 3 on B mode=g: required tool missing) partial_cells=2 (FIDELITY lines above are valid; the run is INCOMPLETE, no RESULT line)\n"
	if rc != 4 || out != want || errs != "" {
		t.Fatalf("rc=%d stderr=%q\n--- got\n%s--- want\n%s", rc, errs, out, want)
	}
	w2 := newWorld(t)
	w2.fixture("B", "class B { 2 }")
	w2.decs["B"] = decBehavior{rc: 3}
	out, _, rc = w2.exec(w2.args())
	if rc != 4 || out != "DEGRADED: reason=decompiler-missing (decompiler exit 3 on B mode=g: required tool missing)\n" {
		t.Fatalf("first-cell degrade: rc=%d %q", rc, out)
	}
}

// TestDegradedCountsFailedCells: partial_cells counts good, diverged and failed cells alike.
func TestDegradedCountsFailedCells(t *testing.T) {
	w := newWorld(t)
	w.fixture("A", "class A { SYNTAX }")
	w.fixture("B", "class B { 2 }")
	w.decs["B"] = decBehavior{rc: 3}
	out, _, _ := w.exec(w.args())
	if !strings.Contains(out, " partial_cells=2 ") {
		t.Fatalf("two FAILED cells came before the degrade:\n%s", out)
	}
}

// TestDecompilerBound: the wrapper gets the RSDD_FIDELITY_TIMEOUT bound (default 720 s); javac/javap get a bound too.
func TestDecompilerBound(t *testing.T) {
	for _, c := range []struct {
		env  []string
		want time.Duration
	}{{nil, 720 * time.Second}, {[]string{"RSDD_FIDELITY_TIMEOUT=2"}, 2 * time.Second}, {[]string{"RSDD_FIDELITY_TIMEOUT=999999"}, 999999 * time.Second}} {
		w := newWorld(t)
		w.fixture("X", "class X { 1 }")
		w.decs["X"] = copyDec(okOut, 0)
		w.exec(w.args(), c.env...)
		for _, call := range w.callsTo(w.dec) {
			if call.Timeout != c.want {
				t.Errorf("decompiler bound %v, want %v", call.Timeout, c.want)
			}
		}
		for _, call := range w.calls {
			if call.Timeout <= 0 {
				t.Errorf("%q run without a bound", call.Argv)
			}
		}
	}
}

// TestRunEnvironment: children run in the caller's cwd with the caller's whole environment.
func TestRunEnvironment(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	w.decs["X"] = copyDec(okOut, 0)
	w.exec(w.args(), "JAVA_TOOL_OPTIONS=-Xmx1m")
	if len(w.calls) == 0 {
		t.Fatal("no run")
	}
	for _, c := range w.calls {
		if c.Dir != w.root {
			t.Errorf("dir %q, want %q", c.Dir, w.root)
		}
		if !strings.Contains(strings.Join(c.Env, "\n"), "JAVA_TOOL_OPTIONS=-Xmx1m") {
			t.Errorf("environment not passed: %q", c.Env)
		}
	}
}

// TestWorkFiles: the per-cell logs are the tools' combined output, byte for byte, at the documented paths.
func TestWorkFiles(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	w.decs["X"] = copyDec(okOut, 0)
	w.exec(w.args())
	base := filepath.Join(w.root, "work", "X", "g")
	got, err := os.ReadFile(filepath.Join(base, "dec.log"))
	if err != nil || string(got) != okOut {
		t.Fatalf("dec.log = %q (%v)", got, err)
	}
	for _, f := range []string{"orig.javap", "re.javap", "lvt.javap", "log"} {
		if _, err := os.Stat(filepath.Join(base, f)); err != nil {
			t.Errorf("missing %s: %v", f, err)
		}
	}
	javap, _ := os.ReadFile(filepath.Join(base, "orig.javap"))
	if !strings.HasPrefix(string(javap), "Compiled from \"X.java\"\n") {
		t.Errorf("orig.javap = %q", javap)
	}
}

// TestRerunClearsCell: a cell directory from an earlier run is wiped, so a stale class cannot be counted.
func TestRerunClearsCell(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	w.decs["X"] = copyDec(okOut, 0)
	stale := filepath.Join(w.root, "work", "X", "g", "orig", "Stale.class")
	if err := os.MkdirAll(filepath.Dir(stale), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, _, _ := w.exec(w.args())
	if !strings.HasPrefix(out, "FIDELITY X mode=g verdict=GOOD\n") {
		t.Fatalf("a stale class from an earlier run leaked into the cell:\n%s", out)
	}
}

// TestDefaultWorkIsRemoved: without --work the scratch directory is under TMPDIR and gone afterwards, also on a degrade.
func TestDefaultWorkIsRemoved(t *testing.T) {
	for _, degrade := range []bool{false, true} {
		w := newWorld(t)
		w.fixture("X", "class X { 1 }")
		w.decs["X"] = copyDec(okOut, 0)
		if degrade {
			w.decs["X"] = decBehavior{rc: 3}
		}
		tmp := filepath.Join(w.root, "tmp")
		if err := os.Mkdir(tmp, 0o755); err != nil {
			t.Fatal(err)
		}
		w.exec([]string{"--fixtures", w.fix}, "TMPDIR="+tmp)
		ents, _ := os.ReadDir(tmp)
		if len(ents) != 0 {
			t.Errorf("degrade=%v: scratch left behind: %v", degrade, ents)
		}
		if len(w.callsTo(w.dec)) == 0 || !strings.HasPrefix(w.callsTo(w.dec)[0].Argv[1], tmp+"/") {
			t.Errorf("degrade=%v: the scratch directory is not under TMPDIR", degrade)
		}
	}
}

// TestWorkDirErrors: an uncreatable --work and an uncreatable default scratch are usage-class failures (rc 2).
func TestWorkDirErrors(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	file := filepath.Join(w.root, "afile")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	out, errs, rc := w.exec([]string{"--fixtures", w.fix, "--work", file})
	if rc != 2 || out != "" || errs != "cannot create --work directory: "+file+"\n" {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
	}
	out, errs, rc = w.exec([]string{"--fixtures", w.fix}, "TMPDIR="+filepath.Join(w.root, "nope"))
	if rc != 2 || out != "" || errs != "cannot create a scratch directory\n" {
		t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
	}
	// An empty TMPDIR falls back to the fixed parent (/tmp in production).
	w.decs["X"] = copyDec(okOut, 0)
	if _, _, rc = w.exec([]string{"--fixtures", w.fix}, "TMPDIR="); rc != 0 {
		t.Fatalf("empty TMPDIR must fall back, rc=%d", rc)
	}
	if got := w.callsTo(w.dec); len(got) == 0 || !strings.HasPrefix(got[len(got)-1].Argv[1], w.tmpFB+"/") {
		t.Fatalf("the fallback scratch parent was not used: %v", got)
	}
}

// TestPartialCellsCountsOne: a degrade after exactly one measured cell names partial_cells=1.
func TestPartialCellsCountsOne(t *testing.T) {
	w := newWorld(t)
	w.fixture("A", "class A { 1 }")
	w.decs["A"] = decBehavior{nogRC: 3, out: okOut, files: map[string]string{"@name.java": "@orig"}}
	out, _, rc := w.exec(w.args())
	if rc != 4 || !strings.Contains(out, " partial_cells=1 ") || !strings.Contains(out, "on A mode=nog:") {
		t.Fatalf("rc=%d\n%s", rc, out)
	}
}

// TestFixtureNamedDotJava: a file called ".java" keeps its name (there is no stem to strip).
func TestFixtureNamedDotJava(t *testing.T) {
	w := newWorld(t)
	if err := os.WriteFile(filepath.Join(w.fix, ".java"), []byte("class Z { 1 }"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.decs[""] = decBehavior{out: okOut, files: map[string]string{".java": "@orig"}} // the fake names the class after the empty stem
	out, _, rc := w.exec(w.args())
	if rc != 0 || !strings.Contains(out, "FIDELITY .java mode=g verdict=GOOD\n") {
		t.Fatalf("rc=%d\n%s", rc, out)
	}
}

// TestKitResolution: without --toolbelt the toolbelt is the resolved kit's; a kit that cannot be found is rc 2.
func TestKitResolution(t *testing.T) {
	w := newWorld(t)
	kit := filepath.Join(w.root, "kit")
	tb := filepath.Join(kit, "toolbelt")
	def := filepath.Join(tb, "tests", "fixtures", "java-fidelity-experiment")
	if err := os.MkdirAll(def, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(def, "D.java"), []byte("class D { 1 }"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.dec = filepath.Join(tb, "decompile-java.sh")
	if err := os.WriteFile(w.dec, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	w.decs["D"] = copyDec(okOut, 0)
	out, errs, rc := w.exec([]string{"--work", filepath.Join(w.root, "wk")}, "RSDD_FIDELITY_DECOMPILER=", "RESEARCH_SDD_KIT="+kit)
	if rc != 0 || !strings.Contains(out, "FIDELITY D mode=g verdict=GOOD\n") {
		t.Fatalf("rc=%d err=%q\n%s", rc, errs, out)
	}
	w.fixture("Z", "class Z { 1 }")
	_, errs, rc = w.exec([]string{"--fixtures", w.fix}, "RSDD_FIDELITY_DECOMPILER=", "RESEARCH_SDD_KIT=", "HOME="+filepath.Join(w.root, "nohome"))
	if rc != 2 || !strings.HasPrefix(errs, "cannot resolve the toolbelt directory (pass --toolbelt DIR or set RESEARCH_SDD_KIT)") {
		t.Fatalf("rc=%d err=%q", rc, errs)
	}
}
