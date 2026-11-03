// Package observed is the shared shape of "what one run of a command printed and returned", for the differential
// and golden tests of the rsdd commands. _test.go symbols cannot be shared across packages, so the type and its
// comparison live here once (kit #2600); a domain imports it from any test file, tagged or not.
package observed

// Run is one run's stdout, stderr and exit code. It is comparable: two runs are equal when all three are.
type Run struct {
	Stdout, Stderr string
	RC             int
}

// New builds a Run from the three values a runner returns.
func New(stdout, stderr string, rc int) Run { return Run{Stdout: stdout, Stderr: stderr, RC: rc} }

// T is the part of *testing.T that Same needs (an interface so the failure path is itself testable).
type T interface {
	Helper()
	Errorf(format string, args ...any)
}

// Same fails t when got differs from want. what names the comparison; want is the legacy script's run.
func Same(t T, what string, want, got Run) {
	t.Helper()
	if want != got {
		t.Errorf("%s differs from the legacy script:\nlegacy rc=%d stdout=%q stderr=%q\n    go rc=%d stdout=%q stderr=%q",
			what, want.RC, want.Stdout, want.Stderr, got.RC, got.Stdout, got.Stderr)
	}
}
