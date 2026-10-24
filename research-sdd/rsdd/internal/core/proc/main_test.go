package proc

import (
	"os"
	"testing"
)

// TestMain lets the test binary stand in for rsdd: started with the hidden
// helper command it becomes the rlimit re-exec helper, so no installed
// binary is needed to exercise the re-exec path.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == HelperCommand {
		os.Exit(HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	os.Exit(m.Run())
}
