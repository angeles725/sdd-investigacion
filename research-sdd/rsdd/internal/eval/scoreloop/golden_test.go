package scoreloop

import (
	"encoding/json"
	"os"
	"testing"
)

// The golden replay: testdata/golden/cases.json freezes the expected stdout, stderr and exit code of every case in
// allCases. For a case the Go command must match the legacy script on, the golden IS the legacy output (the !nodiff
// differential asserts that); for a declared divergence it is the Go output, and the differential asserts the
// legacy side still differs. The replay needs no oracle, so gremlins' nodiff view kills mutants with it.

const goldenPath = "testdata/golden/cases.json"

type goldenEntry struct {
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Exit   int    `json:"exit"`
}

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "scoreloop-repos-")
	if err != nil {
		panic(err)
	}
	repoRoot = dir
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
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

func TestGoldenReplay(t *testing.T) {
	golden := loadGolden(t)
	for _, c := range allCases() {
		t.Run(c.name, func(t *testing.T) {
			want, ok := golden[c.name]
			if !ok {
				t.Fatalf("case %q has no golden entry", c.name)
			}
			got := newWorld(t, c).runGo(t)
			if got.stdout != want.Stdout || got.stderr != want.Stderr || got.exit != want.Exit {
				t.Errorf("golden mismatch\nstdout want %q\n       got  %q\nstderr want %q\n       got  %q\nexit want %d got %d",
					want.Stdout, got.stdout, want.Stderr, got.stderr, want.Exit, got.exit)
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
