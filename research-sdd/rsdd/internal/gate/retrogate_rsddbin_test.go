package gate

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parallelfloor"
)

// The scenarios symlink the live toolbelt/verify-retro.sh, which is a shim over `rsdd retro verify` (kit issue #2586).
// RSDD_BIN points it at a binary built once into a temp dir: an unset RSDD_BIN would make lib/rsdd-exec.sh build into
// the kit's bin/ (the kit-tree hermeticity check) and fail in CI, where no kit binary exists.

var (
	rgBuildOnce sync.Once
	rgBuiltBin  string
	rgBuildErr  error
)

// gateMinParallel is the floor for -test.parallel. Almost every test here waits on child processes (git, bash,
// the frozen originals) rather than computing, so the default of GOMAXPROCS slots leaves a small runner idle while
// its slots sit in wait(2); an explicit -parallel on the command line still wins.
const gateMinParallel = 8

func TestMain(m *testing.M) {
	parallelfloor.Raise(gateMinParallel)
	code := m.Run()
	if rgBuiltBin != "" {
		_ = os.RemoveAll(filepath.Dir(rgBuiltBin))
	}
	os.Exit(code)
}

func rgRsddBin(t testing.TB) string {
	t.Helper()
	rgBuildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "rgshim")
		if err != nil {
			rgBuildErr = err
			return
		}
		rgBuiltBin = filepath.Join(dir, "rsdd")
		goBin, err := exec.LookPath("go")
		if err != nil {
			rgBuildErr = err
			return
		}
		mod, err := filepath.Abs("../..")
		if err != nil {
			rgBuildErr = err
			return
		}
		c := exec.Command(goBin, "build", "-o", rgBuiltBin, "./cmd/rsdd")
		c.Dir = mod
		if out, err := c.CombinedOutput(); err != nil {
			rgBuildErr = &rgBuildFailure{err, string(out)}
		}
	})
	if rgBuildErr != nil {
		t.Fatalf("cannot build rsdd for the verify-retro shim: %v", rgBuildErr)
	}
	return rgBuiltBin
}

type rgBuildFailure struct {
	err error
	out string
}

func (e *rgBuildFailure) Error() string { return e.err.Error() + ": " + e.out }
