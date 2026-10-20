package archtest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFixtureViolationsAreCaught(t *testing.T) {
	r, err := Check(filepath.Join("testdata", "bad"), "example.test/m")
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(r.Violations, "\n")
	for _, want := range []string{
		"alpha imports example.test/m/internal/beta",         // domain -> domain
		"core/lib imports example.test/m/internal/alpha",     // core -> domain
		"delta imports example.test/m/internal/commands",     // domain -> commands
		"core/lib2 imports example.test/m/internal/commands", // core -> commands
		"gamma/g.go: os.Getenv",
		"gamma/g.go: os.LookupEnv",
		"gamma/g.go: time.Now",
		"gamma/g.go: os.Getwd",
		"cli/other.go: os.Getenv",    // only cli/stdio.go is exempt
		"cmd/tool/main.go: time.Now", // cmd/ is scanned too
		"epsilon/e.go: os.Getenv",    // dot-import must not hide the call
		"epsilon/e.go: time.Now",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("violation %q not reported; got:\n%s", want, got)
		}
	}
	// Exempt files really do contain the forbidden calls (see testdata/bad), so
	// "not reported" is a property the scanner has to earn.
	for _, exempt := range []string{"cli/stdio.go", "gamma/g_test.go"} {
		src, err := os.ReadFile(filepath.Join("testdata", "bad", "internal", filepath.FromSlash(exempt)))
		if err != nil || !strings.Contains(string(src), "os.Getenv") {
			t.Fatalf("fixture %s must exist and call os.Getenv for the exemption check to mean anything (err=%v)", exempt, err)
		}
		for _, line := range r.Violations {
			if strings.HasPrefix(line, exempt+":") {
				t.Errorf("%s is exempt but was reported: %s", exempt, line)
			}
		}
	}
	// The registry tier may import any domain.
	for _, line := range r.Violations {
		if strings.HasPrefix(line, "commands imports") {
			t.Errorf("registry import wrongly reported: %s", line)
		}
	}
	if len(r.Violations) != 12 {
		t.Errorf("want exactly 12 violations, got %d:\n%s", len(r.Violations), got)
	}
}

func TestFixtureAllowedImportsPass(t *testing.T) {
	r, err := Check(filepath.Join("testdata", "good"), "example.test/m")
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Violations) != 0 {
		t.Errorf("registry->domain and domain->core are allowed, got: %v", r.Violations)
	}
	if r.Files != 5 {
		t.Errorf("expected 5 files scanned, got %d", r.Files)
	}
	if r.Packages != 5 {
		t.Errorf("expected 5 packages scanned, got %d", r.Packages)
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
	r, err := Check(filepath.Join("..", "..", ".."), mod)
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

// A module without cmd/ is valid (cmd is optional); a missing internal/ is not.
func TestMissingCmdDirIsFine(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "internal", "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "internal", "x", "x.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, err := Check(root, "example.test/m")
	if err != nil || r.Packages != 1 || len(r.Violations) != 0 {
		t.Fatalf("got (%+v, %v), want 1 package, no violations, no error", r, err)
	}
}

// internal/x and cmd/x are different packages; the package key must keep
// the root they were found under.
func TestPackageKeyKeepsRoot(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"internal/x", "cmd/x"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, d, "x.go"), []byte("package x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	r, err := Check(root, "example.test/m")
	if err != nil || r.Packages != 2 {
		t.Fatalf("got (%+v, %v), want 2 distinct packages", r, err)
	}
}
