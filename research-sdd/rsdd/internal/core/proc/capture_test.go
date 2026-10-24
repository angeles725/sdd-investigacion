package proc

import (
	"bytes"
	"testing"
)

// The drain cap bounds memory: past max, each stream keeps nothing more,
// while every byte still counts toward the cap.
func TestCaptureKeepsAtMostMaxBytesPerStream(t *testing.T) {
	c := newCapture(10)
	for range 5 {
		_, _ = c.stream(0).Write(bytes.Repeat([]byte("o"), 7))
		_, _ = c.stream(1).Write(bytes.Repeat([]byte("e"), 7))
	}
	if len(c.bufs[0]) != 10 || len(c.bufs[1]) != 10 || c.total != 70 {
		t.Fatalf("kept %d/%d bytes, counted %d; want 10/10 kept and 70 counted", len(c.bufs[0]), len(c.bufs[1]), c.total)
	}
	select {
	case <-c.hit:
	default:
		t.Fatal("hit not closed after the cap was reached")
	}
}

func TestCaptureWriteReportsTheFullLength(t *testing.T) {
	c := newCapture(1)
	if n, err := c.stream(0).Write([]byte("abc")); n != 3 || err != nil {
		t.Fatalf("Write = %d, %v; want 3, nil so the drain never stalls", n, err)
	}
}
