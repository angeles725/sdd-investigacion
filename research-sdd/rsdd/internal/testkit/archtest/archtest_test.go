package archtest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFixtureViolationsAreCaught(t *testing.T) {
	r, err := Check(filepath.Join("testdata", "bad", "internal"), "example.test/m")
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(r.Violations, "\n")
	for _, want := range []string{
		"alpha imports example.test/m/internal/beta",     // domain -> domain
		"core/lib imports example.test/m/internal/alpha", // core -> domain
	} {
		if !strings.Contains(got, want) {
			t.Errorf("violation %q not reported; got:\n%s", want, got)
		}
	}
	if len(r.Violations) != 2 {
		t.Errorf("want exactly 2 violations, got %d:\n%s", len(r.Violations), got)
	}
}

func TestFixtureAllowedImportsPass(t *testing.T) {
	r, err := Check(filepath.Join("testdata", "good", "internal"), "example.test/m")
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Violations) != 0 {
		t.Errorf("registry->domain and domain->core are allowed, got: %v", r.Violations)
	}
	if r.Packages != 3 {
		t.Errorf("expected 3 packages scanned, got %d", r.Packages)
	}
}

func TestEmptyOrAbsentTreeIsAnError(t *testing.T) {
	if _, err := Check(t.TempDir(), "example.test/m"); err == nil {
		t.Error("a tree with no Go packages must be an error, not a pass")
	}
	if _, err := Check(filepath.Join(t.TempDir(), "absent"), "example.test/m"); err == nil {
		t.Error("an absent tree must be an error")
	}
}

// TestRealTree enforces the rule on the live module.
func TestRealTree(t *testing.T) {
	mod := modulePath(t, filepath.Join("..", "..", "..", "go.mod"))
	r, err := Check(filepath.Join("..", ".."), mod)
	if err != nil {
		t.Fatal(err)
	}
	if r.Packages == 0 {
		t.Fatal("scanned zero packages")
	}
	for _, v := range r.Violations {
		t.Error(v)
	}
}

func modulePath(t *testing.T, gomod string) string {
	t.Helper()
	b, err := os.ReadFile(gomod)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range strings.Split(string(b), "\n") {
		if m, ok := strings.CutPrefix(l, "module "); ok {
			return strings.TrimSpace(m)
		}
	}
	t.Fatal("no module line in go.mod")
	return ""
}
