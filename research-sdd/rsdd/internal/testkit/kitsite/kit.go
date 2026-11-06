package kitsite

import (
	"os"
	"path/filepath"
	"testing"
)

// Kit is a kit at <Home>/investigacion/sdd-investigacion/research-sdd, the default checkout of the resolver, with
// a toolbelt/ directory. Home is a temp dir (symlinks resolved), so no launcher file of the real home is read.
type Kit struct {
	Home, Root string
	profile    Profile
}

// New builds the kit and writes the named files under the kit root (parents created, mode 0755). A file takes
// its body from bodies and is empty when bodies does not name it.
func New(t *testing.T, p Profile, bodies map[string]string, files ...string) Kit {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	k := Kit{Home: home, Root: filepath.Join(home, "investigacion", "sdd-investigacion", "research-sdd"), profile: p}
	mkdir(t, filepath.Join(k.Root, "toolbelt"))
	for _, f := range files {
		path := filepath.Join(k.Root, f)
		mkdir(t, filepath.Dir(path))
		if err := os.WriteFile(path, []byte(bodies[f]), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return k
}

// Bare makes <Home>/bare, a directory without toolbelt/: an invalid RESEARCH_SDD_KIT.
func (k Kit) Bare(t *testing.T) string {
	t.Helper()
	bare := filepath.Join(k.Home, "bare")
	mkdir(t, bare)
	return bare
}

func mkdir(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
}
