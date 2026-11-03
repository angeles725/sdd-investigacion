package kitroot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkModule builds <root>/<kit>/rsdd/go.mod plus a package dir below it (and <kit>/toolbelt when withKit) and
// returns (kit dir, package dir).
func mkModule(t *testing.T, root, kit string, withKit bool) (string, string) {
	t.Helper()
	rs := filepath.Join(root, kit)
	mod := filepath.Join(rs, "rsdd")
	pkg := filepath.Join(mod, "internal", "x")
	dirs := []string{pkg}
	if withKit {
		dirs = append(dirs, filepath.Join(rs, "toolbelt"))
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(mod, "go.mod"), []byte("module m\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return rs, pkg
}

func TestResolveEnvSetWins(t *testing.T) {
	env := t.TempDir()
	got, err := resolve(env, "/nonexistent/wd")
	if err != nil || got != env {
		t.Fatalf("resolve(env) = %q, %v; want %q, nil", got, err, env)
	}
}

func TestResolveEnvUnsetUsesInTreePath(t *testing.T) {
	rs, pkg := mkModule(t, t.TempDir(), "research-sdd", true)
	got, err := resolve("", pkg)
	if err != nil || got != rs {
		t.Fatalf("resolve(\"\", pkg) = %q, %v; want %q, nil", got, err, rs)
	}
}

func TestResolveEnvMissingDirNamesTheVariable(t *testing.T) {
	_, err := resolve(filepath.Join(t.TempDir(), "gone"), "/x")
	if err == nil || !strings.Contains(err.Error(), EnvVar) {
		t.Fatalf("missing env dir: err = %v; want an error naming %s", err, EnvVar)
	}
}

func TestResolveEnvPointingAtAFileIsAnError(t *testing.T) {
	f := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := resolve(f, "/x"); err == nil || !strings.Contains(err.Error(), EnvVar) {
		t.Fatalf("file as env dir: err = %v; want an error naming %s", err, EnvVar)
	}
}

func TestResolveModuleOnlyCopyNamesTheVariable(t *testing.T) {
	// What gremlins' work dir is: a module whose parent exists but holds no toolbelt/.
	_, pkg := mkModule(t, t.TempDir(), "wd", false)
	_, err := resolve("", pkg)
	if err == nil || !strings.Contains(err.Error(), EnvVar) {
		t.Fatalf("module-only copy: err = %v; want an error naming %s", err, EnvVar)
	}
}

func TestResolveNoGoModNamesTheVariable(t *testing.T) {
	_, err := resolve("", t.TempDir())
	if err == nil || !strings.Contains(err.Error(), EnvVar) {
		t.Fatalf("no go.mod: err = %v; want an error naming %s", err, EnvVar)
	}
}

func TestDirReadsTheEnvironment(t *testing.T) {
	env := t.TempDir()
	t.Setenv(EnvVar, env)
	if got := Dir(t); got != env {
		t.Fatalf("Dir = %q; want %q", got, env)
	}
	if got := Path(t, "toolbelt", "lib"); got != filepath.Join(env, "toolbelt", "lib") {
		t.Fatalf("Path = %q", got)
	}
}

func TestMustReadsTheEnvironment(t *testing.T) {
	env := t.TempDir()
	t.Setenv(EnvVar, env)
	if got := Must(); got != env {
		t.Fatalf("Must = %q; want %q", got, env)
	}
}

func TestMustReturnsTheUnresolvedSentinelNamingTheVariable(t *testing.T) {
	t.Setenv(EnvVar, filepath.Join(t.TempDir(), "gone"))
	got := Must()
	if got != Unresolved || !strings.Contains(got, EnvVar) {
		t.Fatalf("Must = %q; want the sentinel %q naming %s", got, Unresolved, EnvVar)
	}
	if _, err := os.ReadFile(filepath.Join(got, "toolbelt", "x")); err == nil || !strings.Contains(err.Error(), EnvVar) {
		t.Fatalf("reading below the sentinel: err = %v; want an error naming %s", err, EnvVar)
	}
}

func TestDirInTreeIsTheRealKit(t *testing.T) {
	t.Setenv(EnvVar, "")
	d := Dir(t)
	if st, err := os.Stat(filepath.Join(d, "toolbelt")); err != nil || !st.IsDir() {
		t.Fatalf("Dir() = %q has no toolbelt/: %v", d, err)
	}
}
