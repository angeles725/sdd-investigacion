package proc

import (
	"bytes"
	"testing"
	"time"
)

// These kills used to come only from the Python parity test, which the
// nodiff teeth run excludes.

func TestGraceDefaultsOnlyWhenUnset(t *testing.T) {
	if g := (Spec{}).grace(); g != DefaultGrace {
		t.Errorf("unset grace = %v, want DefaultGrace %v", g, DefaultGrace)
	}
	if g := (Spec{Grace: 7 * time.Millisecond}).grace(); g != 7*time.Millisecond {
		t.Errorf("explicit grace = %v, want 7ms", g)
	}
}

func TestCaptureReachedAtExactlyMax(t *testing.T) {
	c := newCapture(4)
	_, _ = c.stream(0).Write([]byte("abc"))
	if c.reached() {
		t.Fatal("reached after 3 of 4 bytes")
	}
	_, _ = c.stream(1).Write(bytes.Repeat([]byte("e"), 1))
	if !c.reached() {
		t.Fatal("not reached after exactly 4 of 4 bytes (stdout and stderr count jointly)")
	}
}

func TestFinalReason(t *testing.T) {
	for _, tc := range []struct {
		watched string
		capHit  bool
		want    string
	}{
		{"", false, ""},
		{"", true, ReasonOutputCap},
		{ReasonTimeout, true, ReasonTimeout},
		{ReasonTimeout, false, ReasonTimeout},
		{ReasonOutputCap, true, ReasonOutputCap},
	} {
		if got := finalReason(tc.watched, tc.capHit); got != tc.want {
			t.Errorf("finalReason(%q, %v) = %q, want %q", tc.watched, tc.capHit, got, tc.want)
		}
	}
}
