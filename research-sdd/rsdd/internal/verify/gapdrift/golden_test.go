package gapdrift

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Recorded goldens: what the frozen check-gap-drift.sh printed (stdout, stderr, exit code) for every case of the
// shared tables, as the Go command prints it. This test runs in BOTH builds. The default build also compares the Go
// side against the bash script (differential_test.go), so a golden that differs from the script cannot be recorded
// green; the nodiff build (what mutation testing compiles) replays only the Go side against the file, which is what
// kills mutants without bash.
//
// A stale golden FAILS. Re-record deliberately, in the default build, with
//
//	go test ./internal/verify/gapdrift/ -run 'Golden|Differential' -update-gapdrift
var updateGoldens = flag.Bool("update-gapdrift", false, "re-record testdata/golden/cases.golden from the Go side (default build, after the differential passes)")

var goldenPath = filepath.Join("testdata", "golden", "cases.golden")

// goldenEntry runs one case in-process and renders it: the corpus directory is written {D}, so the entry does not
// depend on where the temporary directory is.
func goldenEntry(t *testing.T, c runCase) string {
	t.Helper()
	dir := corpus(t, c.files)
	args := make([]string, len(c.args))
	for i, a := range c.args {
		args[i] = strings.ReplaceAll(a, "{D}", dir)
	}
	got := runGo(dir, args...)
	norm := func(s string) string { return strings.ReplaceAll(s, dir, "{D}") }
	return fmt.Sprintf("%s\n  args   %q\n  files  %s\n  exit   %d\n  stdout %q\n  stderr %q\n",
		c.name, c.args, digestFiles(c.files), got.code, norm(got.stdout), norm(got.stderr))
}

// digestFiles pins the corpus bytes of a case without repeating them: a changed file changes the digest.
func digestFiles(files map[string]string) string {
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	h := sha256.New()
	for _, n := range names {
		fmt.Fprintf(h, "%q:%q;", n, files[n])
	}
	return fmt.Sprintf("n=%d sha256=%x", len(files), h.Sum(nil)[:8])
}

func TestGoldens(t *testing.T) {
	cases := append(outcomeCases(), generatedCases()...)
	names := make([]string, len(cases))
	entries := make(map[string]string, len(cases))
	for i, c := range cases {
		names[i] = c.name
		entries[c.name] = goldenEntry(t, c)
	}
	if len(entries) != len(cases) {
		t.Fatalf("%d cases share %d names: golden names must be unique", len(cases), len(entries))
	}
	if *updateGoldens {
		var b strings.Builder
		for _, n := range names {
			b.WriteString(entries[n])
		}
		if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenPath, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("recorded %d golden entries", len(names))
		return
	}
	raw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("golden file: %v (record it with -update-gapdrift in the default build)", err)
	}
	// Entries are six lines: the name, then args, files, exit, stdout and stderr.
	const perEntry = 6
	recorded := map[string]string{}
	lines := strings.SplitAfter(string(raw), "\n")
	for i := 0; i+perEntry <= len(lines); i += perEntry {
		recorded[strings.TrimSuffix(lines[i], "\n")] = strings.Join(lines[i:i+perEntry], "")
	}
	if len(recorded) != len(names) {
		t.Errorf("the golden file holds %d entries, the case tables produce %d: stale golden (re-record with -update-gapdrift)", len(recorded), len(names))
	}
	for _, n := range names {
		want, ok := recorded[n]
		if !ok {
			t.Errorf("%s: no golden recorded (re-record with -update-gapdrift)", n)
			continue
		}
		if want != entries[n] {
			t.Errorf("%s: differs from the golden\n--- golden\n%s--- go\n%s", n, want, entries[n])
		}
	}
}
