//go:build linux

package fsx

import (
	"errors"
	"strings"
	"testing"
)

func TestErrorUnwrapAndMessage(t *testing.T) {
	e := &Error{Kind: ErrTooLarge}
	if e.Error() != "input exceeds max-input-bytes" || !errors.Is(e, ErrTooLarge) || errors.Is(e, ErrOpen) {
		t.Fatalf("bad error %v", e)
	}
	if !strings.HasSuffix((&Error{Kind: ErrOpen, Path: "/p"}).Error(), ": /p") {
		t.Fatal("path suffix missing")
	}
}
