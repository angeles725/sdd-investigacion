package corpus

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

// The rsdd binary every archive run gets as RSDD_BIN, in BOTH builds (the default and -tags nodiff). The archive
// runs real rsdd shims (verify-state.sh, verify-corrections.sh); without RSDD_BIN each shim builds rsdd into the
// kit's bin/ itself, concurrently from parallel cases. That breaks the kit-tree check, and under the nodiff build
// the gremlins teeth job uses, it made a passing case read REFUSED in CI (kit issue #2625). The binary is built
// once into a temp dir from the module under test, so a mutant is compiled into it.

var (
	archiveBuildOnce sync.Once
	archiveBuiltBin  string
	archiveBuildErr  error
)

func init() { archiveTestBin = archiveRsddBin }

// TestMain removes the shared rsdd binary directory after the whole package ran: no single test owns it.
func TestMain(m *testing.M) {
	code := m.Run()
	if archiveBuiltBin != "" {
		_ = os.RemoveAll(filepath.Dir(archiveBuiltBin))
	}
	os.Exit(code)
}

func archiveRsddBin(t testing.TB) string {
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
