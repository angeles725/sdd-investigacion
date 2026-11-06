package toolcatalog

import (
	"bytes"
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Recorded goldens: what the frozen scripts printed (stdout, stderr, exit code) for every case of the shared tables,
// as the Go commands print it. This test runs in BOTH builds. The default build also compares the Go side against
// the bash scripts (differential_test.go), so a golden that differs from the scripts cannot be recorded green; the
// nodiff build (what mutation testing compiles) replays only the Go side against the file, which is what kills
// mutants without bash.
//
// A stale golden FAILS. Re-record deliberately, in the default build, with
//
//	go test ./internal/verify/toolcatalog/ -run 'Golden|Differential' -update-toolcatalog
var updateGoldens = flag.Bool("update-toolcatalog", false, "re-record testdata/golden/cases.golden from the Go side (default build, after the differential passes)")

var goldenPath = filepath.Join("testdata", "golden", "cases.golden")

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

// entry renders one observed run: the temporary directory is written {D}, so the entry does not depend on where it is.
func entry(name, digest, dir string, o observed) string {
	norm := func(s string) string { return strings.ReplaceAll(s, dir, "{D}") }
	return fmt.Sprintf("%s\n  input  %s\n  exit   %d\n  stdout %q\n  stderr %q\n", name, digest, o.code, norm(o.stdout), norm(o.stderr))
}

func goldenEntries(t *testing.T) (names []string, entries map[string]string) {
	t.Helper()
	entries = map[string]string{}
	add := func(name, e string) {
		names = append(names, name)
		entries[name] = e
	}
	for _, c := range append(checkCases(), hookCases()...) {
		for _, loc := range locales {
			dir := kit(t, c.files)
			run := Run
			if c.hook {
				run = RunHook
			}
			o := runGo(dir, loc, run, append([]string{dir}, c.args...)...)
			add(c.name+" ["+loc+"]", entry(c.name+" ["+loc+"]", digestFiles(c.files)+" args="+fmt.Sprint(c.args), dir, o))
		}
	}
	for _, c := range stubCases() {
		var buf bytes.Buffer
		emitHook(&buf, strings.TrimRight(c.out, "\n"), c.rc, c.full)
		o := observed{buf.String(), "", 0}
		add(c.name, entry(c.name, fmt.Sprintf("out=%d bytes sha256=%x rc=%d full=%v", len(c.out), sha256.Sum256([]byte(c.out)), c.rc, c.full), "", o))
	}
	return names, entries
}

func TestGoldens(t *testing.T) {
	t.Parallel()
	names, entries := goldenEntries(t)
	if len(entries) != len(names) {
		t.Fatalf("%d cases share %d names: golden names must be unique", len(names), len(entries))
	}
	var b strings.Builder
	for _, n := range names {
		b.WriteString(entries[n])
	}
	if *updateGoldens {
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
		t.Fatalf("golden file: %v (record it with -update-toolcatalog in the default build)", err)
	}
	if got := b.String(); got != string(raw) {
		recorded := strings.Split(string(raw), "\n")
		for i, l := range strings.Split(got, "\n") {
			if i >= len(recorded) || l != recorded[i] {
				t.Fatalf("golden mismatch at line %d:\n   got %q\n  want %q\n(re-record deliberately with -update-toolcatalog)", i+1, l, recorded[min(i, len(recorded)-1)])
			}
		}
		t.Fatalf("golden file has %d more line(s) than the run", len(recorded)-len(strings.Split(got, "\n")))
	}
}
