package gaprows

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Recorded goldens: the answers of the frozen lib/gap-rows.sh, as the Go package gives them, for every case of the
// shared tables. This test runs in BOTH builds. The default build also compares the Go side against the bash oracle
// (differential_test.go), so a golden that differs from the oracle cannot be recorded green; the nodiff build (what
// mutation testing compiles) replays only the Go side against the file, which is what kills mutants without bash.
//
// A stale golden FAILS. Re-record deliberately, in the default build, with
//
//	go test ./internal/core/gaprows/ -run 'Golden|Differential' -update-gaprows
var updateGoldens = flag.Bool("update-gaprows", false, "re-record testdata/golden/cases.golden from the Go side (default build, after the differential passes)")

var goldenPath = filepath.Join("testdata", "golden", "cases.golden")

// renderTable prints every field of every record, so a wrong line number or a wrong flag is visible.
func renderTable(tb Table) string {
	var b strings.Builder
	fmt.Fprintf(&b, "empty=%v n=%d", tb.Empty, len(tb.Records))
	for _, r := range tb.Records {
		fmt.Fprintf(&b, " | kind=%d line=%d id=%q block=%q pending=%v text=%q cell=%q source=%q", r.Kind, r.Line, r.ID, r.Block, r.Pending, r.Text, r.Cell, r.Source)
	}
	return b.String()
}

func renderBullet(src, id string) string {
	text, found := ParseBullets(src).Text(id)
	return fmt.Sprintf("found=%v text=%q", found, text)
}

func renderOverlap(row, bullet string) string {
	s, n := Overlap(row, bullet)
	return fmt.Sprintf("shared=%d total=%d", s, n)
}

// goldenEntries computes every golden entry in a fixed order.
func goldenEntries() (names []string, entries map[string]string) {
	entries = map[string]string{}
	add := func(name, in, out string) {
		names = append(names, name)
		entries[name] = fmt.Sprintf("%s\n  in  %s\n  out %s\n", name, in, out)
	}
	for _, c := range fixtureStates() {
		add("parse/"+c.name, fmt.Sprintf("%q", c.src), renderTable(Parse(c.src)))
	}
	for _, c := range fixtureBulletCases() {
		add("bullet/"+c.name+"/"+c.id, fmt.Sprintf("%q", c.src), renderBullet(c.src, c.id))
	}
	for _, c := range fixtureOverlapCases() {
		add("overlap/"+c.name, fmt.Sprintf("%q %q", c.row, c.bullet), renderOverlap(c.row, c.bullet))
	}
	for _, c := range genCorpus() {
		add("parse/"+c.name, digest(c.state), renderTable(Parse(c.state)))
		for g, id := range c.ids {
			add(fmt.Sprintf("bullet/%s/%d/%s", c.name, g, id), digest(c.block), renderBullet(c.block, id))
		}
		add("overlap/"+c.name, fmt.Sprintf("%q %q", c.row, c.bullet), renderOverlap(c.row, c.bullet))
	}
	return names, entries
}

func TestGoldens(t *testing.T) {
	names, entries := goldenEntries()
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
		t.Fatalf("golden file: %v (record it with -update-gaprows in the default build)", err)
	}
	// Entries are three lines: the name, the input, the output.
	recorded := map[string]string{}
	lines := strings.SplitAfter(string(raw), "\n")
	for i := 0; i+2 < len(lines); i += 3 {
		recorded[strings.TrimSuffix(lines[i], "\n")] = lines[i] + lines[i+1] + lines[i+2]
	}
	if len(recorded) != len(names) {
		t.Errorf("the golden file holds %d entries, the case tables produce %d: stale golden (re-record with -update-gaprows)", len(recorded), len(names))
	}
	for _, n := range names {
		want, ok := recorded[n]
		if !ok {
			t.Errorf("%s: no golden recorded (re-record with -update-gaprows)", n)
			continue
		}
		if want != entries[n] {
			t.Errorf("%s: differs from the golden\n--- golden\n%s--- go\n%s", n, want, entries[n])
		}
	}
}

// digest stands in for a long generated input: its length and a SHA-256 prefix pin the bytes without repeating them.
func digest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return fmt.Sprintf("len=%d sha256=%x", len(s), sum[:8])
}
