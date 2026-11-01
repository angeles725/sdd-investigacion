package corpus

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// toolbelt/research-sdd-archive.sh is now a compatibility shim over `rsdd corpus archive`. These tests run the REAL shim
// with RSDD_BIN pointing at a binary built into a temp dir (never the kit's bin/: an unset RSDD_BIN would build there and
// break the kit-tree check) and hold it to the frozen legacy script.

var (
	archiveBuildOnce sync.Once
	archiveBuiltBin  string
	archiveBuildErr  error
)

func archiveRsddBin(t *testing.T) string {
	t.Helper()
	archiveBuildOnce.Do(func() {
		dir, err := os.MkdirTemp(os.Getenv("TMPDIR"), "archshim")
		if err != nil {
			archiveBuildErr = err
			return
		}
		archiveBuiltBin = filepath.Join(dir, "rsdd")
		goBin, err := exec.LookPath("go")
		if err != nil {
			archiveBuildErr = err
			return
		}
		c := exec.Command(goBin, "build", "-o", archiveBuiltBin, "./cmd/rsdd")
		c.Dir = archiveReal(t, "../..")
		if out, err := c.CombinedOutput(); err != nil {
			archiveBuildErr = &archiveBuildFailure{err, string(out)}
		}
	})
	if archiveBuildErr != nil {
		t.Fatalf("cannot build rsdd for the shim test: %v", archiveBuildErr)
	}
	return archiveBuiltBin
}

type archiveBuildFailure struct {
	err error
	out string
}

func (b *archiveBuildFailure) Error() string { return b.err.Error() + ": " + b.out }

func TestArchiveShimMatchesLegacy(t *testing.T) {
	if why := archiveHaveTools(); why != "" {
		t.Skip(why)
	}
	if testing.Short() {
		t.Skip("builds the rsdd binary")
	}
	bin := archiveRsddBin(t)
	t.Cleanup(func() { _ = os.RemoveAll(filepath.Dir(bin)) })
	realTB := archiveReal(t, archiveKitRel+"/toolbelt")
	shim := filepath.Join(realTB, "research-sdd-archive.sh")
	for _, tc := range []struct {
		name  string
		build func(f *archiveFx) string
		args  func(d string) []string
	}{
		{"clean", func(f *archiveFx) string { d := f.path("c"); f.mkgood(d); return d }, func(d string) []string { return []string{d} }},
		{"dry-run", func(f *archiveFx) string { d := f.path("c"); f.mkgood(d); return d }, func(d string) []string { return []string{d, "--dry-run"} }},
		{"stale", func(f *archiveFx) string {
			d := f.path("c")
			f.mkgood(d)
			f.replaceIn(filepath.Join(d, "RESEARCH-STATE.md"), "2 / 3 closed", "3 / 3 closed")
			return d
		}, func(d string) []string { return []string{d} }},
		{"usage", func(f *archiveFx) string { d := f.path("c"); f.mkgood(d); return d }, func(string) []string { return nil }},
		{"unknown-focus", func(f *archiveFx) string { d := f.path("c"); f.mkgood(d); return d }, func(d string) []string { return []string{d, "--focus", "zz"} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, err := os.MkdirTemp(os.Getenv("TMPDIR"), "archshimcase")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { archiveWipe(t, root) })
			for _, d := range []string{"home", "tmp", "work"} {
				_ = os.MkdirAll(filepath.Join(root, d), 0o755)
			}
			f := &archiveFx{t: t, root: root, cdir: filepath.Join(root, "work", "case"), tb: archiveFarm(t, root)}
			if err := os.MkdirAll(f.cdir, 0o755); err != nil {
				t.Fatal(err)
			}
			d := tc.build(f)
			pristine := filepath.Join(root, "pristine")
			archiveCopy(t, f.cdir, pristine)
			env := archiveBaseEnv(root)
			restore := func() { archiveWipe(t, f.cdir); archiveCopy(t, pristine, f.cdir) }

			restore()
			lo, le, lc := archiveRunLegacy(t, f.tb, root, tc.args(d), env)
			lt := archiveTree(t, f.cdir)

			restore()
			c := exec.Command("bash", append([]string{shim}, tc.args(d)...)...)
			c.Dir, c.Env = root, append(append([]string(nil), env...), "RSDD_BIN="+bin)
			var o, e strings.Builder
			c.Stdout, c.Stderr = &o, &e
			sc := archiveExit(t, c.Run())
			st := archiveTree(t, f.cdir)

			// KNOWN DIVERGENCE (reported out of surface): cli.Run appends a generic DEGRADED: line to every command that
			// ends on exit 3, and for this tool 3 means REFUSED by a gate. Nothing else may differ.
			const generic = "DEGRADED: command reported a degraded state without a reason\n"
			shimErr := e.String()
			if sc == 3 {
				if !strings.HasSuffix(shimErr, generic) {
					t.Errorf("a refused run must end with the dispatcher's generic line, stderr %q", shimErr)
				}
				shimErr = strings.TrimSuffix(shimErr, generic)
			}

			// the legacy ran from the toolbelt copy, the shim from the real toolbelt: only that path differs
			norm := func(s string) string {
				return strings.ReplaceAll(strings.ReplaceAll(s, realTB, "@TB@"), f.tb, "@TB@")
			}
			if sc != lc || norm(o.String()) != norm(lo) || norm(shimErr) != norm(le) || st != lt {
				t.Errorf("shim differs from the legacy script (stdout same: %v, stderr same: %v, tree same: %v)\nexit %d vs %d\n--- legacy\n%s\n%s\n--- shim\n%s\n%s", norm(o.String()) == norm(lo), norm(shimErr) == norm(le), st == lt, lc, sc, norm(lo), norm(le), norm(o.String()), norm(shimErr))
			}
		})
	}
}

// Without a binary and without a Go toolchain the shim reports a typed degraded state; it never passes silently.
func TestArchiveShimDegradesWithoutBinary(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	shim := filepath.Join(archiveReal(t, archiveKitRel+"/toolbelt"), "research-sdd-archive.sh")
	c := exec.Command("bash", shim, t.TempDir())
	c.Env = []string{"PATH=" + os.Getenv("PATH"), "RSDD_BIN=" + filepath.Join(t.TempDir(), "missing")}
	var e strings.Builder
	c.Stderr = &e
	code := archiveExit(t, c.Run())
	if code != 2 || !strings.Contains(e.String(), "degraded: rsdd-unavailable") {
		t.Errorf("exit %d, stderr %q", code, e.String())
	}
}
