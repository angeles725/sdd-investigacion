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
		// one entry per tier rule, with the reason text so a wrong-rule hit does not pass
		"alpha imports example.test/m/internal/beta: a domain may import only the core tier",     // domain -> domain
		"core/lib imports example.test/m/internal/alpha: core tier must not import domains",      // core -> domain
		"cli imports example.test/m/internal/alpha: core tier must not import domains",           // cli (core tier) -> domain
		"delta imports example.test/m/internal/commands: a domain may import only the core tier", // domain -> commands
		"core/lib2 imports example.test/m/internal/commands: core tier must not import domains",  // core -> commands
		"gamma/g.go: os.Getenv",
		"gamma/g.go: os.LookupEnv",
		"gamma/g.go: time.Now",
		"gamma/g.go: os.Getwd",
		"gamma/g.go: os.Environ",        // #2387
		"cli/other.go: os.Getenv",       // only cli/stdio.go is exempt
		"cmd/tool/main.go: time.Now",    // cmd/ is scanned too
		"commands/c.go: os.Getenv",      // the registry tier is not exempt from the call ban
		"dotimp/d.go: dot-import of os", // `import . "os"` would hide every ambient read
	} {
		if !strings.Contains(got, want) {
			t.Errorf("violation %q not reported; got:\n%s", want, got)
		}
	}
	// Exempt files: the stdio file and test files. The fixtures hold ambient
	// calls in both, so these assertions are not vacuous.
	for _, line := range r.Violations {
		if strings.HasPrefix(line, "cli/stdio.go:") || strings.Contains(line, "_test.go") {
			t.Errorf("exempt file was reported: %s", line)
		}
	}
	if len(r.Violations) != 14 {
		t.Errorf("want exactly 14 violations, got %d:\n%s", len(r.Violations), got)
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
	if r.Files != 6 {
		t.Errorf("expected 6 files scanned, got %d", r.Files)
	}
	if r.Packages != 6 {
		t.Errorf("expected 6 packages scanned, got %d", r.Packages)
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
