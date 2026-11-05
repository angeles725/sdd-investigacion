package secretscan

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"
)

// The golden replay: testdata/golden/cases.json freezes the expected stdout, stderr and exit code of every case in
// allCases. For a case the engine must match the legacy script on, the golden IS the legacy output (the !nodiff
// differential asserts that); for a declared divergence it is the Go output, and the differential asserts the
// legacy side still differs. The replay needs no oracle, so gremlins' nodiff view kills mutants with it.

const goldenPath = "testdata/golden/cases.json"

type goldenEntry struct {
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Exit   int    `json:"exit"`
}

func loadGolden(t testing.TB) map[string]goldenEntry {
	t.Helper()
	b, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("golden file: %v", err)
	}
	var m map[string]goldenEntry
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("golden file: %v", err)
	}
	if len(m) == 0 {
		t.Fatal("golden file holds no cases (an empty corpus proves nothing)")
	}
	return m
}

// canon sorts the stdout lines of an unordered case (a multi-file walk reports in directory order). Only the legacy
// side of the differential goes through it; the golden of such a case holds the engine's exact output.
func canon(c scase, o obs) obs {
	if !c.unordered {
		return o
	}
	lines := strings.Split(o.stdout, "\n")
	sort.Strings(lines)
	o.stdout = strings.Join(lines, "\n")
	return o
}

func TestGoldenReplay(t *testing.T) {
	t.Parallel()
	golden := loadGolden(t)
	for _, c := range allCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			want, ok := golden[c.name]
			if !ok {
				t.Fatalf("case %q has no golden entry", c.name)
			}
			got := newWorld(t, c).runGo(t) // exact: for an unordered case the golden pins the engine's own sorted order
			exp := obs{want.Stdout, want.Stderr, want.Exit}
			if got != exp {
				t.Errorf("golden mismatch\nstdout want %q\n       got  %q\nstderr want %q\n       got  %q\nexit want %d got %d",
					exp.stdout, got.stdout, exp.stderr, got.stderr, exp.exit, got.exit)
			}
		})
	}
}

func TestGoldenHasNoStrayEntries(t *testing.T) {
	names := map[string]bool{}
	for _, c := range allCases() {
		if names[c.name] {
			t.Errorf("duplicate case name %q", c.name)
		}
		names[c.name] = true
	}
	for name := range loadGolden(t) {
		if !names[name] {
			t.Errorf("golden entry %q matches no case", name)
		}
	}
}
