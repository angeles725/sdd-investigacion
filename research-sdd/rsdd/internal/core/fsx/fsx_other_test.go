//go:build !linux

package fsx

import (
	"errors"
	"testing"
)

// Off Linux every kernel-bound operation is a typed unavailable error; none
// may degrade to a weaker primitive.
func TestNonLinuxOperationsAreUnavailable(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := OpenRO(dir + "/a"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("OpenRO: %v", err)
	}
}
