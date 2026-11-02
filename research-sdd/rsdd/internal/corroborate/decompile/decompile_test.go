// Old suite -> Go. toolbelt/tests/decompile-java.test.sh used to hold every contract of decompile-java.sh, and its
// --prove-teeth section ran ~70 sed mutants of the script. The script is a shim now; each old case and each old
// mutant is a Go test here. Nothing below sleeps: a hanging engine moves a fake clock, and the process runner is a
// fake (the Go stub in fake_test.go is a port of the suite's bash engine stub, STUB_* knobs included).
//
//	old case / mutant                                     Go test
//	a b c d e  engine argv per engine and input shape     TestEngineArgv
//	NJ0 NJ1 A6 mNJ1  success; exit 0 with no source       TestScenarios/ok, /NJ1
//	A1 A2 A3 mA1 mA2 mA3  timeout, error, no fallback     TestScenarios/A1, /A2, /A3
//	A1b-A1f mRETRIED mJAVAP-ARM  host-stall retry         none: the stub no longer sleeps, nothing can stall
//	A4 mA4  no timeout binary                             TestScenarios/A4, TestEngineBounds, TestClassfileHeader
//	A5 A5b  --timeout abc / 0                             TestUsage, TestEngineBounds
//	B1-B9 C1-C8 E1-E8 F1-F6b G H1-H4 I1-I5 J1-J4 K1-K3    TestScenarios/<same tag> (75+ captured legacy runs)
//	L1-L3 M1-M3 P1 Q1 R1 S1-S5c  (tag = the old case)     TestScenarios/<same tag>
//	mB1 mB2 mB3 mE1-mE4 mH1-mH3 mI1-mI3 mK1-mK3 mS1-mS5   killed by the TestScenarios row of the case they named
//	mC1 mC2 mF1 mG1 (marker regexp mutants)               TestMarkerRegexp
//	mF2 mC3 mF3 mF4 mJ1-mJ3 mN2-mN5                       TestScenarios + TestIsolationClamp + TestBudgetEdge
//	mE2 mL1 mS2a-mS2g (inner / generated classes)         TestIsUnitClass, TestScenarios/E6, /L1, /S2*
//	H1-H4 (CLASSFILE line, warning) mCF1 mCF2             TestClassfileHeader, TestFactsRunner
//	H6 H6b H14 mCF4 mCF5 (helper fails: facts-error)      TestClassfileHeader
//	H7 H7b H8 H9 mCF6 mCF7 mCF8 mCF13 (helper budget)     TestClassfileHeader, TestFactsBudget, TestFactsRunner
//	H10 H11 mCF9 (invalid RSDD_CLASSFACTS_TIMEOUT)        TestFactsBudget
//	H12 mCF10 (no timeout binary: facts-unbounded)        TestClassfileHeader
//	H5 H13 H15 H1p mCF3 mCF11 mCF12 mCF14 mCF15           removed with the Python fallback and the rsdd binary
//	                                                      resolution: the facts are read in process now, so there
//	                                                      is no helper to be absent, to be named wrongly, or to
//	                                                      take over; the shim's own wiring is the bash suite's
//	H1r H3r (real binary end to end)                      the bash suite's real-binary case, TestFactsRunnerReal
//
// Decisions the captured table reaches only by accident each have a case in decisions_test.go (scratch parent and
// name, the 2 s freshness window, what makes a fallback a success, the unzip command line, the sweep's reason
// codes, a failed extraction being forgotten, the exact warning texts, the process limits) and in the extra
// scenario rows Q2 Q3 X1-X8 (stale vs fresh output, root package, nested package, WEB-INF / versioned layouts,
// budget exhaustion with a marked fallback), captured from the legacy script like the rest.
//
// New contracts pinned only by Go: usage and validation order (TestUsage), Java resolution and --javap
// (TestJavaResolution, TestJavap), the exit-1 abort on a failed mkdir (TestFatal), exit statuses of the process
// runner (TestExitStatus, TestProcRunner), file-copy and discard rules (TestCopyTree, TestDiscard).

package decompile

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// scenario is one row of the captured table (scenarios_test.go): the old suite's case, its input, the STUB_*
// knobs, and the legacy script's observed behaviour.
type scenario struct {
	tag, input string
	env        map[string]string
	args       []string
	preseed    [][]string // path, age, content: stale files already in a reused out-dir
	outSuffix  string
	rc         int
	stdout     string
	tree       []string
	calls      []string
}

var ages = map[string]time.Duration{"2 days ago": 48 * time.Hour, "1 second ago": time.Second}

// TestScenarios replays every captured scenario through the Go port against the Go engine stub, on a fake clock,
// and compares exit status, stdout, the out-dir tree and the exact engine invocations with what the legacy script
// did. Nothing sleeps: a hanging engine moves the fake clock.
func TestScenarios(t *testing.T) {
	for _, sc := range scenarios {
		t.Run(sc.tag, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range sc.env {
				w.env[k] = strings.ReplaceAll(v, "@missing", filepath.Join(w.root, "no-such"))
			}
			in := filepath.Join(w.root, "Test.class")
			if sc.input == "class" {
				w.touch("Test.class")
			} else {
				in = w.input(sc.input+".jar", inputs[sc.input])
			}
			out := filepath.Join(w.root, "o-"+sc.tag)
			for _, p := range sc.preseed {
				f := filepath.Join(out, p[0])
				content := "// engine=stale"
				if len(p) > 2 {
					content = p[2]
				}
				if strings.HasSuffix(p[0], "/") {
					w.mkdir(f)
				} else {
					w.write(f, content+"\n")
				}
				mt := w.clock.Now().Add(-ages[p[1]])
				if err := os.Chtimes(f, mt, mt); err != nil {
					t.Fatal(err)
				}
			}
			args := sc.args
			if args == nil {
				args = []string{"--engine", "vineflower"}
			}
			stdout, stderr, rc := w.exec(append([]string{in, out + sc.outSuffix}, args...)...)
			if rc != sc.rc {
				t.Errorf("exit %d, want %d\nstderr: %s", rc, sc.rc, stderr)
			}
			if got := w.norm(stdout, in, out); got != sc.stdout {
				t.Errorf("stdout:\n%s\nwant:\n%s", got, sc.stdout)
			}
			if got := tree(t, out); !reflect.DeepEqual(got, orEmpty(sc.tree)) {
				t.Errorf("out-dir tree:\n%q\nwant:\n%q", got, sc.tree)
			}
			// The legacy script built the root package's class path as "ext/./Root.class"; the Go port cleans it.
			dot := strings.NewReplacer("/./", "/", " ./", " ")
			var calls, want []string
			for _, c := range w.engineLog {
				calls = append(calls, dot.Replace(w.norm(c, in, out)))
			}
			for _, c := range sc.calls {
				want = append(want, dot.Replace(c))
			}
			if !reflect.DeepEqual(orEmpty(calls), orEmpty(want)) {
				t.Errorf("engine calls:\n%q\nwant:\n%q", calls, want)
			}
		})
	}
}

func orEmpty(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
