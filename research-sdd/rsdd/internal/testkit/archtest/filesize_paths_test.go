package archtest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The go tool ignores directories and files whose name starts with "." or "_", so they are not part of the module
// and the ratchet does not read them: a scratch copy under a dot directory, a draft, an editor's lock symlink.
func TestScanSkipsPathsTheGoToolIgnores(t *testing.T) {
	root, dp := tree(t, map[string]string{
		".scratch/a.go":      gen(300),
		"_old/b.go":          gen(500),
		"pkg/_draft.go":      gen(300),
		"pkg/.hidden.go":     gen(300),
		"pkg/under_score.go": gen(10),
		"pkg/dot.inside.go":  gen(10),
		"sub_dir/c.go":       gen(10),
		"v1.2/d.go":          gen(10),
	}, "")
	// What Emacs leaves beside an unsaved buffer: a dangling symlink whose name ends in .go.
	if err := os.Symlink("nowhere", filepath.Join(root, "pkg", ".#lock.go")); err != nil {
		t.Fatal(err)
	}
	r, err := CheckFileSizes(root, dp)
	if err != nil {
		t.Fatalf("an ignored path was read: %v", err)
	}
	if r.Scanned != 4 || r.Over != 0 || len(r.Violations) != 0 {
		t.Errorf("scanned=%d over=%d violations=%q, want the four ordinary files and nothing else", r.Scanned, r.Over, r.Violations)
	}
}

// The rule is about what is under the root, never about the root's own name.
func TestScanReadsARootWhateverItsOwnName(t *testing.T) {
	for _, name := range []string{".mod", "_mod", "testdata"} {
		root := filepath.Join(t.TempDir(), name)
		if err := os.Mkdir(root, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "a.go"), []byte(gen(10)), 0o644); err != nil {
			t.Fatal(err)
		}
		dp := filepath.Join(root, DebtFileName)
		if err := os.WriteFile(dp, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if r, err := CheckFileSizes(root, dp); err != nil || r.Scanned != 1 {
			t.Errorf("root named %q: scanned=%d err=%v, want its one file", name, r.Scanned, err)
		}
	}
}

// One line pasted in the wrong place is one message about that place. Every entry is still read, so no listed
// file is reported as unlisted.
func TestOneMisplacedLineYieldsOneMessage(t *testing.T) {
	files := map[string]string{"a.go": gen(300), "b.go": gen(300), "c.go": gen(300), "z.go": gen(300)}
	debt := debtLine("z.go", 300, "legacy") + debtLine("a.go", 300, "legacy") + debtLine("b.go", 300, "legacy") + debtLine("c.go", 300, "legacy")
	r := check(t, files, debt)
	if want := badMsg(2, "a.go is not after z.go (unsorted)"); len(r.Violations) != 1 || r.Violations[0] != want {
		t.Errorf("violations = %q, want only %q", r.Violations, want)
	}
	if r.Entries != 4 {
		t.Errorf("entries = %d, want all 4 read", r.Entries)
	}
}

// A path listed twice is a duplicate wherever its second line stands, and the second line is not judged again.
func TestDuplicateFarFromItsFirstLine(t *testing.T) {
	files := map[string]string{"a.go": gen(301), "b.go": gen(300)}
	debt := debtLine("a.go", 300, "legacy") + debtLine("b.go", 300, "legacy") + debtLine("a.go", 300, "legacy")
	r := check(t, files, debt)
	want := []string{
		"a.go: grew from 300 to 301 lines. Split it, or change its line in modularity-debt.txt to:\na.go 301 legacy " + reason,
		badMsg(3, "duplicate path a.go"),
	}
	if !sameStrings(r.Violations, want) {
		t.Errorf("violations = %q, want %q", r.Violations, want)
	}
}

// The line the not-listed message prints is refused until its placeholder is replaced, by name and not by the
// accident of its length.
func TestThePrintedLineIsRefusedUntilItHasAReason(t *testing.T) {
	r := check(t, map[string]string{"a.go": gen(250)}, "")
	if len(r.Violations) != 1 {
		t.Fatalf("violations = %q", r.Violations)
	}
	printed := r.Violations[0][strings.LastIndex(r.Violations[0], "\n")+1:]
	if _, bad := parseDebt(printed + "\n"); len(bad) != 1 || bad[0] != badMsg(1, "replace <reason> with the reason this file is accepted") {
		t.Errorf("pasted as printed: %q", bad)
	}
	edited := strings.Replace(printed, "<reason>", "split planned with the verify move", 1)
	if es, bad := parseDebt(edited + "\n"); len(es) != 1 || len(bad) != 0 {
		t.Errorf("with a real reason: es=%v bad=%q", es, bad)
	}
}

// A failed write is not a rewrite.
func TestUpdateReportsNoRewriteWhenTheWriteFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can write into a read-only directory")
	}
	stale := debtLine("a.go", 300, "legacy")
	root, dp := tree(t, map[string]string{"a.go": gen(250)}, stale)
	if err := os.Chmod(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })
	changed, err := UpdateDebt(root, dp)
	got, _ := os.ReadFile(dp)
	if err == nil || changed || string(got) != stale {
		t.Errorf("changed=%v err=%v file=%q, want an error, no rewrite and the file as it was", changed, err, got)
	}
}
