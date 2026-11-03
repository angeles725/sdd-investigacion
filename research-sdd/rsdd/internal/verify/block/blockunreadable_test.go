//go:build unix

package block

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/observed"
)

// bkUnreadableBlock writes a canonical block with [CERT] markers and a cite, then removes every permission from it.
// It skips when the process can still read a mode-000 file (root).
func bkUnreadableBlock(t *testing.T) (dir, block string) {
	t.Helper()
	dir = t.TempDir()
	block = filepath.Join(dir, "unread-block1.md")
	if err := os.WriteFile(block, []byte("# Block 1 — t\n\n> Type: evidence. Method: [CERT] = x.\n\n---\n\nSee `a.sh:1`.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.sh"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(block, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(block, 0o644) }) //nolint:errcheck // so t.TempDir can remove it
	if f, err := os.Open(block); err == nil {
		f.Close()
		t.Skip("a mode-000 file is still readable here (running as root)")
	}
	return dir, block
}

// TestBlockUnreadableIsNeverClean: an unreadable block must not read as clean (CLAUDE.md §7). The scans that read it
// report DEGRADED exactly as the script printed them, the run exits 1, and stderr names the read failure.
func TestBlockUnreadableIsNeverClean(t *testing.T) {
	dir, block := bkUnreadableBlock(t)
	got := bkGo(dir, []string{filepath.Base(block), dir}, []string{"HOME=" + dir, "LC_ALL=C.UTF-8"})
	if got.RC != 1 {
		t.Errorf("rc = %d, want 1", got.RC)
	}
	for _, want := range []string{
		"   ERROR: empty-digest scan DEGRADED (awk exit 2, no scan trailer) — block NOT checked for empty-input digests\n",
		"   ERROR: ephemeral-path scan DEGRADED (awk exit 2, no scan trailer) — block NOT checked for ephemeral cites\n",
		"   DEGRADED backptr: the sentence scan or the candidate directory failed (awk exit 2, 1 directories) — back-pointers NOT checked\n",
		" · 1 degraded (correction sentences: 0;",
		"== exit 1 ==\n",
	} {
		if !strings.Contains(got.Stdout, want) {
			t.Errorf("stdout lacks %q\n%s", want, got.Stdout)
		}
	}
	for _, clean := range []string{"(none — no unwaived cited hash", "(none — no unanchored ephemeral path", "(none — no correction sentence"} {
		if strings.Contains(got.Stdout, clean) {
			t.Errorf("an unreadable block reported a clean section: %q", clean)
		}
	}
	if !strings.Contains(got.Stderr, "verify-block.sh: cannot read unread-block1.md: ") {
		t.Errorf("stderr does not name the read failure: %q", got.Stderr)
	}
}

// TestBlockLocaleIndependent pins the intended difference documented in tool-registry.d/verify-block.md: the port
// measures text in characters whatever the caller's locale, so LC_ALL=C (where the script's awk counted bytes) gives
// the same report as C.UTF-8 on a block whose correction sentence is long and non-ASCII.
func TestBlockLocaleIndependent(t *testing.T) {
	dir := t.TempDir()
	long := strings.Repeat("é—", 70)
	for name, body := range map[string]string{
		"x-block1.md": "# Block 1 — old\n\nNothing points forward.\n",
		"x-block2.md": "# Block 2 — new\n\nThis corrects [Block 1] and the sentence names it " + long + ".\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run := func(loc string) observed.Run {
		return bkGo(dir, []string{"x-block2.md", dir}, []string{"HOME=" + dir, "LC_ALL=" + loc})
	}
	utf8, c := run("C.UTF-8"), run("C")
	if !strings.Contains(utf8.Stdout, "BACKPTR?") {
		t.Fatalf("fixture premise: no back-pointer candidate\n%s", utf8.Stdout)
	}
	if utf8 != c {
		t.Errorf("the report depends on the locale:\n--- C.UTF-8\n%s\n--- C\n%s", utf8.Stdout, c.Stdout)
	}
}
