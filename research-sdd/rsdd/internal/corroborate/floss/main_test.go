//go:build unix

package floss

import (
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestMain lets the test binary stand in for rsdd: started with the hidden helper command it becomes the
// rlimit re-exec helper (the sandboxed run goes through it), so no installed binary is needed.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	os.Exit(m.Run())
}
