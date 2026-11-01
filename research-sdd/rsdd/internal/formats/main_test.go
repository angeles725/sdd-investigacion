//go:build unix

package formats

import (
	"os"
	"syscall"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestMain lets the test binary stand in for rsdd: started with the hidden helper command it becomes the
// rlimit re-exec helper (the extraction runs its sandbox through it), so no installed binary is needed.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	syscall.Umask(0o022) // the modes the tests expect from files the fake sandbox creates
	// The manifest tool these commands call (analysis_manifest.py) execs the rsdd binary when it can; on the
	// CI runner that child crashed under the test RLIMIT_AS cap (#2463). An unusable RSDD_BIN makes the shim
	// fall back to the Python implementation, which the analysis-manifest suite pins; the Go manifest has its
	// own tests in its package.
	if os.Getenv("RSDD_BIN") == "" {
		_ = os.Setenv("RSDD_BIN", "/nonexistent/rsdd-disabled-in-formats-tests")
	}
	os.Exit(m.Run())
}
