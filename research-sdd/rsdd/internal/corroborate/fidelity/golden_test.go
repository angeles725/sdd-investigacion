package fidelity

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The fast lane for the real fixtures: testdata/javap holds the real `javap -c -p` and `javap -l -p` output of
// the six fixtures in tests/fixtures/java-fidelity-experiment, captured once with a real JDK (testdata/javap/JDK
// names it). The pipeline runs over that real text through the fake runner, so no JVM starts. The live JVM run is
// the slow lane of tests/java-fidelity-experiment.test.sh (RSDD_TEST_LANE=slow).

const realFixtures = "../../../../toolbelt/tests/fixtures/java-fidelity-experiment"

var realNames = []string{"EnhancedFor", "LabeledBreak", "LambdaCapture", "StringSwitch", "SynchronizedBlock", "TryWithResources"}

func TestRealJavapGoldens(t *testing.T) {
	w := newWorld(t)
	abs, err := filepath.Abs(realFixtures)
	if err != nil {
		t.Fatal(err)
	}
	w.fix = abs
	w.golden, _ = filepath.Abs("testdata/javap")
	for _, n := range realNames {
		w.decs[n] = copyDec(okOut, 0)
	}
	out, errs, rc := w.exec(w.args())
	if rc != 0 || errs != "" {
		t.Fatalf("rc=%d err=%q\n%s", rc, errs, out)
	}
	yes := 0
	for _, n := range realNames {
		for _, mode := range []string{"g", "nog"} {
			if line := "FIDELITY " + n + " mode=" + mode + " verdict=GOOD\n"; !strings.Contains(out, line) {
				t.Errorf("missing %q in\n%s", line, out)
			}
		}
		want := map[string]string{"g": "no", "nog": "no"}
		for mode := range want {
			b, err := os.ReadFile(filepath.Join("testdata/javap", n+"."+mode+".l.txt"))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(b), "LocalVariableTable") {
				want[mode] = "yes"
				yes++
			}
		}
		line := "DEBUGINFO " + n + " g_lvt=" + want["g"] + " nog_lvt=" + want["nog"] + "\n"
		if !strings.Contains(out, line) {
			t.Errorf("missing %q in\n%s", line, out)
		}
		if want["nog"] != "no" {
			t.Errorf("%s: a compile without -g must carry no LocalVariableTable", n)
		}
	}
	if yes == 0 {
		t.Error("no captured fixture shows a LocalVariableTable with -g: the capture proves nothing")
	}
	if !strings.HasSuffix(out, " constructs=6 cells=12 good=12 diverged=0 failed=0\n") {
		t.Errorf("summary:\n%s", out)
	}
}

var anyPoolRef = regexp.MustCompile(`#[0-9]+`)

// TestRealJavapNormalisation: real listings carry pool references and the header, and normalise removes both.
func TestRealJavapNormalisation(t *testing.T) {
	files, err := filepath.Glob("testdata/javap/*.c.txt")
	if err != nil || len(files) != len(realNames)*2 {
		t.Fatalf("captured listings: %d (%v), want %d", len(files), err, len(realNames)*2)
	}
	poolSeen := 0
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		raw := string(b)
		if !strings.HasPrefix(raw, "Compiled from \"") {
			t.Errorf("%s: no Compiled from header", f)
		}
		got := normalise(b)
		if anyPoolRef.MatchString(got) || strings.Contains(got, "Compiled from") {
			t.Errorf("%s: normalised text still carries a pool reference or the header", f)
		}
		if anyPoolRef.MatchString(raw) {
			poolSeen++
		}
		if strings.Count(raw, "\n")-1 != strings.Count(got, "\n") {
			t.Errorf("%s: normalise must remove exactly the header line", f)
		}
		// The same listing under shifted pool numbers compares equal; one changed offset does not.
		shifted := anyPoolRef.ReplaceAllString(raw, "#999")
		if !sameBytecode(b, []byte(shifted)) {
			t.Errorf("%s: pool renumbering must not matter", f)
		}
		if strings.Contains(raw, "   0: ") && sameBytecode(b, []byte(strings.Replace(raw, "   0: ", "   1: ", 1))) {
			t.Errorf("%s: an offset change must be seen", f)
		}
	}
	if poolSeen == 0 {
		t.Error("no captured listing has a constant-pool reference: the capture proves nothing")
	}
}
