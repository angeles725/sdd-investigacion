package hook

import (
	"os"
	"path/filepath"
	"testing"
)

// envOf builds a hermetic Env: only the listed variables exist.
func envOf(cwd string, kv map[string]string) Env {
	return Env{Cwd: cwd, Getenv: func(k string) string { return kv[k] }}
}

// sandbox returns a fresh root and an Env whose walk-up ceiling is the root's
// parent, so no fixture can see a .git above its own sandbox (the TMPDIR
// bleed-in hazard of hook-wiring.test.sh case 13a).
func sandbox(t *testing.T) (string, Env) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return root, envOf(root, map[string]string{envCeiling: filepath.Dir(root)})
}

func mkdirs(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

// gitInit makes dir its own git root without needing a git binary.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	mkdirs(t, filepath.Join(dir, ".git"))
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	mkdirs(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func wireSettings(t *testing.T, dir, json string) {
	t.Helper()
	writeFile(t, filepath.Join(dir, ".claude", "settings.json"), json)
}

func symlink(t *testing.T, oldname, newname string) {
	t.Helper()
	mkdirs(t, filepath.Dir(newname))
	if err := os.Symlink(oldname, newname); err != nil {
		t.Fatal(err)
	}
}
