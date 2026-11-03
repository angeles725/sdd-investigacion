//go:build !nodiff && unix

package gaprows

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Differential tests: the frozen lib/gap-rows.sh (testdata/legacy, the bytes before the port) and this package must
// agree on gap_rows_parse, gap_bullet_text and gap_overlap. A host without bash or GNU awk FAILS the test with a typed
// message: a skipped differential proves nothing.

var (
	oracleOnce sync.Once
	oracleErr  error
)

func requireOracle(t *testing.T) {
	t.Helper()
	oracleOnce.Do(func() {
		for _, tool := range []string{"bash", "awk"} {
			if _, err := exec.LookPath(tool); err != nil {
				oracleErr = fmt.Errorf("oracle tool %q not on PATH: %w", tool, err)
				return
			}
		}
		out, err := exec.Command("awk", "--version").CombinedOutput()
		if err != nil || !strings.HasPrefix(string(out), "GNU Awk") {
			oracleErr = fmt.Errorf("the default awk is not GNU awk (gawk): %q", strings.SplitN(string(out), "\n", 2)[0])
		}
	})
	if oracleErr != nil {
		t.Fatalf("differential: the oracle host is incomplete; gaprows is NOT proven against lib/gap-rows.sh: %v", oracleErr)
	}
}

var legacyLib, legacyLibErr = filepath.Abs(filepath.Join("testdata", "legacy", "gap-rows.sh"))

// bash runs one function of the frozen lib. Its stdout and exit code are returned.
func bash(t *testing.T, fn string, args ...string) (string, int) {
	t.Helper()
	requireOracle(t)
	if legacyLibErr != nil {
		t.Fatalf("differential: cannot resolve the oracle path: %v", legacyLibErr)
	}
	cmd := exec.Command("bash", append([]string{"-c", `. "$1"; shift; fn=$1; shift; "$fn" "$@"`, "_", legacyLib, fn}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "LC_ALL=C.UTF-8"}
	out, err := cmd.Output()
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("legacy %s: %v", fn, err)
		}
		code = ee.ExitCode()
	}
	return string(out), code
}

func writeTemp(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "in.md")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// legacyShape renders Go records the way gap_rows_parse prints them.
func legacyShape(tb Table) string {
	var b strings.Builder
	for _, r := range tb.Records {
		switch r.Kind {
		case KindRow:
			st := "other"
			if r.Pending {
				st = "pending"
			}
			fmt.Fprintf(&b, "ROW\t%s\t%s\t%s\t%s\n", r.ID, r.Block, st, r.Text)
		case KindSkipped:
			fmt.Fprintf(&b, "SKIPPED\t%s\n", r.Cell)
		case KindUnparsed:
			fmt.Fprintf(&b, "UNPARSED\t%s\n", r.Source)
		}
	}
	return b.String()
}

func assertParse(t *testing.T, name, src string) {
	t.Helper()
	want, code := bash(t, "gap_rows_parse", writeTemp(t, src))
	if code != 0 {
		t.Fatalf("%s: legacy gap_rows_parse exited %d", name, code)
	}
	if got := legacyShape(Parse(src)); got != want {
		t.Errorf("%s: Parse differs from gap_rows_parse\nlegacy: %q\ngo:     %q", name, want, got)
	}
}

func assertBullet(t *testing.T, name, src, id string) {
	t.Helper()
	want, code := bash(t, "gap_bullet_text", writeTemp(t, src), id)
	got, found := ParseBullets(src).Text(id)
	switch {
	case code == 0 && !found:
		t.Errorf("%s %s: legacy found %q, Go found nothing", name, id, want)
	case code == 1 && found:
		t.Errorf("%s %s: legacy found nothing, Go found %q", name, id, got)
	case code >= 2:
		t.Fatalf("%s %s: legacy exited %d", name, id, code)
	case code == 0 && got+"\n" != want:
		t.Errorf("%s %s: bullet differs\nlegacy: %q\ngo:     %q", name, id, want, got+"\n")
	}
}

func assertOverlap(t *testing.T, name, row, bullet string) {
	t.Helper()
	out, code := bash(t, "gap_overlap", row, bullet)
	if code != 0 {
		t.Fatalf("%s: legacy gap_overlap exited %d", name, code)
	}
	s, n := Overlap(row, bullet)
	if want := fmt.Sprintf("%d %d\n", s, n); out != want {
		t.Errorf("%s: overlap legacy %q, go %q (row %q, bullet %q)", name, out, want, row, bullet)
	}
}

func TestDifferentialFixtures(t *testing.T) {
	for _, c := range fixtureStates() {
		assertParse(t, c.name, c.src)
	}
	for _, c := range fixtureBulletCases() {
		assertBullet(t, c.name, c.src, c.id)
	}
	for _, c := range fixtureOverlapCases() {
		assertOverlap(t, c.name, c.row, c.bullet)
	}
}

// TestDifferentialGenerated runs the seeded corpora (genSeeds) of generated state files, block files and word lists
// against the frozen lib. The seeds are fixed so a failure reproduces; the same corpora are recorded as goldens.
func TestDifferentialGenerated(t *testing.T) {
	for _, c := range genCorpus() {
		assertParse(t, c.name, c.state)
		for _, id := range c.ids {
			assertBullet(t, c.name, c.block, id)
		}
		assertOverlap(t, c.name, c.row, c.bullet)
	}
}

// The frozen oracle is pinned by hash, so an edit to it cannot go unnoticed.
func TestLegacyOracleIsPinned(t *testing.T) {
	sums, err := os.ReadFile(filepath.Join("testdata", "legacy", "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		want, rel, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 {
			t.Fatalf("malformed SHA256SUMS line %q", line)
		}
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", rel))
		if err != nil {
			t.Fatalf("pinned file missing: %v", err)
		}
		if got := sha256.Sum256(b); hex.EncodeToString(got[:]) != want {
			t.Errorf("%s changed: sha256 %x, pinned %s", rel, got, want)
		}
		n++
	}
	if n != 1 {
		t.Errorf("%d files pinned; the oracle is lib/gap-rows.sh alone", n)
	}
}
