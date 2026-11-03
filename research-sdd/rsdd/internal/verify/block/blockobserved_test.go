//go:build unix

package block

import "testing"

// observed is what one run of a verify-block implementation printed and returned. It lives in an untagged file
// (not a !nodiff one) because the golden replay and the mutant run, which build with nodiff, compare it too. It
// mirrors the same-named test type of the other verify commands on purpose: _test.go symbols cannot be shared
// across packages, and sharing it would need a testkit package those commands do not use yet.
type observed struct {
	stdout, stderr string
	rc             int
}

func same(t *testing.T, what string, want, got observed) {
	t.Helper()
	if want != got {
		t.Errorf("%s differs from the legacy script:\nlegacy rc=%d stdout=%q stderr=%q\n    go rc=%d stdout=%q stderr=%q",
			what, want.rc, want.stdout, want.stderr, got.rc, got.stdout, got.stderr)
	}
}
