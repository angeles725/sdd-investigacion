//go:build unix

package floss

// Host-independent tests of the output-path and tool-resolution steps of run(). They need no bwrap, floss or
// Python and no particular mount layout on the host: the mountinfo is a seam, PATH is a directory the test
// owns, and every assertion is on the exact error text, so a mutant that changes which error fires is killed
// on a bare CI runner as well as on a developer machine (issue #2561).

import (
	"math/big"
	"os"
	"path/filepath"
	"testing"
)

// hermeticRun runs the command against a private mountinfo and returns the exact error text.
func hermeticRun(t *testing.T, cwd, output string, env map[string]string) string {
	t.Helper()
	old := readMountinfo
	readMountinfo = func() (string, error) { return "1 0 0:1 / / rw - tmpfs tmpfs rw\n", nil }
	t.Cleanup(func() { readMountinfo = old })
	s := envOf(env)
	s.Cwd = cwd
	var stage string
	_, err := run(options{input: "in", output: output, timeout: big.NewInt(1), maxStrings: big.NewInt(1), maxStringLen: big.NewInt(1)}, s, &stage)
	if stage != "" {
		t.Errorf("run created a stage directory %q before tool resolution", stage)
	}
	if err == nil {
		t.Fatalf("output %q: want an error, got none", output)
	}
	return err.Error()
}

// fakeTool writes an executable file named name into dir.
func fakeTool(t *testing.T, dir, name string) {
	t.Helper()
	must(t, os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\nexit 0\n"), 0o755))
}

func TestRunOutputCollisionRefusalsAreExact(t *testing.T) {
	root := t.TempDir()
	bin := t.TempDir() // a PATH that holds neither bwrap nor floss
	env := map[string]string{"PATH": bin}
	must(t, os.WriteFile(filepath.Join(root, "file"), nil, 0o644))
	must(t, os.Symlink(filepath.Join(root, "nowhere"), filepath.Join(root, "dangling")))
	const collide = "output must be a new non-colliding path"
	for _, c := range []struct{ name, out, want string }{
		{"existing file (Stat and Lstat)", "file", collide},
		{"dangling symlink (Lstat only)", "dangling", collide},
		{"existing parent directory", ".", collide},
		// A fresh name under an existing parent is not a collision: the run goes on to tool resolution.
		{"fresh name", "fresh", "PATH-selected bwrap is missing"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := hermeticRun(t, root, c.out, env); got != c.want {
				t.Errorf("output %q: error %q, want %q", c.out, got, c.want)
			}
		})
	}
	if _, err := os.Lstat(filepath.Join(root, "fresh")); err == nil {
		t.Error("a refused run left the output behind")
	}
}

func TestRunMissingBwrapStopsBeforeFloss(t *testing.T) {
	root := t.TempDir()
	bin := t.TempDir()
	fakeTool(t, bin, "floss") // floss is resolvable; only bwrap is missing
	if got := hermeticRun(t, root, "fresh", map[string]string{"PATH": bin}); got != "PATH-selected bwrap is missing" {
		t.Errorf("error %q, want the bwrap resolution error", got)
	}
}

func TestRunResolvedBwrapGoesOnToFloss(t *testing.T) {
	root := t.TempDir()
	bin := t.TempDir()
	fakeTool(t, bin, "bwrap") // bwrap resolves; floss does not, so the run must reach and report floss
	if got := hermeticRun(t, root, "fresh", map[string]string{"PATH": bin}); got != "PATH-selected floss is missing" {
		t.Errorf("error %q, want the floss resolution error", got)
	}
}

func TestRunUnresolvableParentIsTheEvalSymlinksError(t *testing.T) {
	root := t.TempDir()
	missing := filepath.Join(root, "nodir")
	want := "lstat " + missing + ": no such file or directory"
	if got := hermeticRun(t, root, "nodir/out", map[string]string{"PATH": t.TempDir()}); got != want {
		t.Errorf("error %q, want %q", got, want)
	}
}
