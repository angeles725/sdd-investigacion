package archtest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gen returns n lines of Go-ish content, each ending in \n.
func gen(n int) string { return strings.Repeat("// x\n", n) }

// tree writes files (path -> content) under a fresh temp root plus a debt
// file with the given text, and returns both paths.
func tree(t *testing.T, files map[string]string, debt string) (root, debtPath string) {
	t.Helper()
	root = t.TempDir()
	for p, c := range files {
		full := filepath.Join(root, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	debtPath = filepath.Join(root, DebtFileName)
	if err := os.WriteFile(debtPath, []byte(debt), 0o644); err != nil {
		t.Fatal(err)
	}
	return root, debtPath
}

func check(t *testing.T, files map[string]string, debt string) SizeResult {
	t.Helper()
	root, dp := tree(t, files, debt)
	r, err := CheckFileSizes(root, dp)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestCountLines(t *testing.T) {
	for _, tt := range []struct {
		name, in string
		want     int
	}{
		{"empty", "", 0},
		{"one line with newline", "a\n", 1},
		{"one line without newline", "a", 1},
		{"two lines no trailing newline", "a\nb", 2},
		{"blank lines count", "\n\n", 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := countLines([]byte(tt.in)); got != tt.want {
				t.Errorf("countLines(%q) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}

func TestLineCountBoundariesAtSoftLimit(t *testing.T) {
	r := check(t, map[string]string{"a/at200.go": gen(200), "a/at201.go": gen(201)}, "")
	if r.Over != 1 || r.Scanned != 2 {
		t.Errorf("want Over=1 Scanned=2, got %+v", r)
	}
	want := "a/at201.go: 201 lines, over 200 and not listed. Split it, or add this line to modularity-debt.txt:\na/at201.go 201 accepted <reason>"
	if len(r.Violations) != 1 || r.Violations[0] != want {
		t.Errorf("violations = %q, want [%q]", r.Violations, want)
	}
}

func TestNoTrailingNewlineCountsLastLine(t *testing.T) {
	// 200 newline-terminated lines plus one unterminated line is 201.
	r := check(t, map[string]string{"f.go": gen(200) + "x"}, "")
	if r.Over != 1 || len(r.Violations) != 1 || !strings.HasPrefix(r.Violations[0], "f.go: 201 lines") {
		t.Errorf("got %+v", r)
	}
}

func TestEmptyFileIsZeroLines(t *testing.T) {
	r := check(t, map[string]string{"empty.go": "", "b.go": gen(1)}, "")
	if r.Scanned != 2 || r.Over != 0 || len(r.Violations) != 0 {
		t.Errorf("got %+v", r)
	}
}

func TestScopeSkipsTestsAndTestdata(t *testing.T) {
	r := check(t, map[string]string{
		"a/big_test.go":          gen(500),
		"a/testdata/big.go":      gen(500),
		"testdata/x/deep/big.go": gen(500),
		"a/ok.go":                gen(5),
		"a/notgo.txt":            gen(500),
	}, "")
	if r.Scanned != 1 || r.Over != 0 || len(r.Violations) != 0 {
		t.Errorf("want only a/ok.go scanned, got %+v", r)
	}
}

func TestZeroProductionFilesIsAnError(t *testing.T) {
	root, dp := tree(t, map[string]string{"a_test.go": gen(3), "testdata/x.go": gen(3)}, "")
	if _, err := CheckFileSizes(root, dp); err == nil {
		t.Error("a tree with no production file must be an error, not a pass")
	}
}

func TestAbsentDebtFileIsAnError(t *testing.T) {
	root, dp := tree(t, map[string]string{"a.go": gen(3)}, "")
	if err := os.Remove(dp); err != nil {
		t.Fatal(err)
	}
	if _, err := CheckFileSizes(root, dp); err == nil {
		t.Error("an absent debt file must be an error")
	}
}

func TestEmptyDebtFileIsValidWhenNothingIsOver(t *testing.T) {
	r := check(t, map[string]string{"a.go": gen(200)}, "")
	if r.Entries != 0 || r.Over != 0 || len(r.Violations) != 0 {
		t.Errorf("got %+v", r)
	}
}

func TestUnreadableSourceFileIsAnError(t *testing.T) {
	root, dp := tree(t, map[string]string{"a.go": gen(3)}, "")
	// A dangling symlink cannot be read by any user, root included.
	if err := os.Symlink(filepath.Join(root, "missing"), filepath.Join(root, "b.go")); err != nil {
		t.Skipf("cannot create a symlink here: %v", err)
	}
	if _, err := CheckFileSizes(root, dp); err == nil {
		t.Error("an unreadable source file must be an error, not a smaller scan")
	}
	if _, err := UpdateDebt(root, dp); err == nil {
		t.Error("update mode must refuse a tree it cannot read in full")
	}
}
