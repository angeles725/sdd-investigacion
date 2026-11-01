package skilldrift

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Parity of `rsdd verify skill-drift` with the frozen legacy script (testdata/legacy, sha-pinned in harness_test.go).
//
//   - TestDriftParity runs the frozen script and the Go command live on the same fixture, same environment, and compares
//     stdout, stderr and exit code byte for byte (scratch root and mktemp names normalised);
//   - TestDriftGolden compares the Go command to testdata/golden/drift-<case>/{stdout,stderr,exit}, recorded from the frozen
//     script (`go test -run TestDriftGolden -update` re-records);
//   - both also hold the Go output to what the legacy suite asserted for the case (rc, has, not, silent) and to the rule that no
//     temp dir survives a run.
//
// A case marked diverg is an intended divergence (intended.go): it is checked against its expectations only.

func driftSkips(t *testing.T, c dcase) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	if c.root {
		notRoot(t)
	}
}

func expect(t *testing.T, c dcase, r result) {
	t.Helper()
	if r.code != c.rc {
		t.Errorf("exit = %d, want %d (stderr %q)", r.code, c.rc, r.err)
	}
	if k, ok := hasAll(r.err, c.has); !ok {
		t.Errorf("stderr lacks %q:\n%s", k, r.err)
	}
	for _, n := range c.not {
		if strings.Contains(r.err, n) {
			t.Errorf("stderr contains %q:\n%s", n, r.err)
		}
	}
	if c.silent && (r.out != "" || r.err != "") {
		t.Errorf("expected silence, got stdout %q stderr %q", r.out, r.err)
	}
}

func TestDriftParity(t *testing.T) {
	for _, c := range driftCases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			driftSkips(t, c)
			w := c.setupWorld(t)
			env := w.runEnv(c.env)
			got := w.norm(w.runGoDrift(c.args, env))
			if left := w.leftover(); len(left) != 0 {
				t.Errorf("the Go run left temp entries behind: %v", left)
			}
			expect(t, c, got)
			if c.diverg {
				return
			}
			want := w.norm(w.runBash("verify-skill-drift.sh", c.args, env))
			if left := w.leftover(); len(left) != 0 {
				t.Fatalf("the oracle left temp entries behind: %v", left)
			}
			if got != want {
				t.Errorf("parity broken\n--- legacy (exit %d)\nstdout: %q\nstderr: %q\n--- go (exit %d)\nstdout: %q\nstderr: %q",
					want.code, want.out, want.err, got.code, got.out, got.err)
			}
		})
	}
}

func goldenDir(name string) string { return filepath.Join("testdata", "golden", name) }

func readGolden(t *testing.T, name string) result {
	t.Helper()
	d := goldenDir(name)
	code, err := strconv.Atoi(strings.TrimSpace(readFile(t, filepath.Join(d, "exit"))))
	if err != nil {
		t.Fatalf("%s/exit: %v", d, err)
	}
	return result{readFile(t, filepath.Join(d, "stdout")), readFile(t, filepath.Join(d, "stderr")), code}
}

func writeGolden(t *testing.T, name string, r result) {
	t.Helper()
	d := goldenDir(name)
	write(t, filepath.Join(d, "stdout"), r.out, 0o644)
	write(t, filepath.Join(d, "stderr"), r.err, 0o644)
	write(t, filepath.Join(d, "exit"), fmt.Sprintf("%d\n", r.code), 0o644)
}

func TestDriftGolden(t *testing.T) {
	if !*update {
		// a golden directory that no case owns would never be compared: it must not exist
		ents, err := os.ReadDir(filepath.Join("testdata", "golden"))
		if err != nil {
			t.Fatalf("testdata/golden: %v (record with -update)", err)
		}
		owned := map[string]bool{}
		for _, c := range driftCases {
			if !c.diverg {
				owned["drift-"+c.name] = true
			}
		}
		for _, h := range hookCases {
			if h.oracle && !h.diverg {
				owned["hook-"+h.name] = true
			}
		}
		for _, e := range ents {
			if !owned[e.Name()] {
				t.Errorf("golden %s belongs to no case", e.Name())
			}
		}
	}
	for _, c := range driftCases {
		if c.diverg {
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			driftSkips(t, c)
			w := c.setupWorld(t)
			env := w.runEnv(c.env)
			if *update {
				writeGolden(t, "drift-"+c.name, w.norm(w.runBash("verify-skill-drift.sh", c.args, env)))
				return
			}
			got := w.norm(w.runGoDrift(c.args, env))
			if want := readGolden(t, "drift-"+c.name); got != want {
				t.Errorf("golden mismatch\n--- golden (exit %d)\nstdout: %q\nstderr: %q\n--- go (exit %d)\nstdout: %q\nstderr: %q",
					want.code, want.out, want.err, got.code, got.out, got.err)
			}
		})
	}
}
