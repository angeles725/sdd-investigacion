//go:build linux

package serial

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A usage error names the sub-command when one was chosen and only the program otherwise.
func TestUsageErrorProgName(t *testing.T) {
	good := "testdata/frames/basic.log"
	_, _, stderr := analyze(t, "stats", "--input", good)
	if !strings.Contains(stderr, "\nserial-frame-analyze stats: error: the following arguments are required: --output\n") {
		t.Errorf("sub-command error = %q", stderr)
	}
	_, _, stderr = analyze(t, "bogus")
	if !strings.Contains(stderr, "\nserial-frame-analyze: error: argument cmd: invalid choice: 'bogus'\n") {
		t.Errorf("top-level error = %q", stderr)
	}
}

// A 4-byte-lead and a 3-byte-lead sequence cut short at the last valid byte of the continuation range.
func TestPyDecodeReplaceUpperBounds(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"\xe1\xbf", "�"},
		{"\xe1\xc0", "��"},
		{"\xf1\xbf\xbf", "�"},
		{"\xf1\xbf\xc0", "��"},
	} {
		if got := pyDecodeReplace([]byte(tc.in)); got != tc.want {
			t.Errorf("pyDecodeReplace(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// Rates at the edges of the accepted range configure on a pseudo-terminal: 0 (B0) and the largest termios2 rate;
// one past it is refused by the port code with the pyserial "Could not configure port" text.
func TestPTYBaudEdges(t *testing.T) {
	_, slave := openPTY(t)
	p, err := openSerialPort(slave, 0, time.Now)
	if err != nil {
		t.Fatalf("baud 0: %v", err)
	}
	_ = p.Close()
	p, err = openSerialPort(slave, 0xffffffff, time.Now)
	if err != nil {
		t.Fatalf("baud 0xffffffff: %v", err)
	}
	_ = p.Close()
	_, err = openSerialPort(slave, 0x100000000, time.Now)
	if err == nil || err.Error() != "Could not configure port: (22, 'Invalid argument')" {
		t.Errorf("baud 2**32: err = %v, want the configure error", err)
	}
}

// Read returns as soon as n bytes are in hand; it does not wait out the timeout.
func TestTTYReadStopsAtN(t *testing.T) {
	master, slave := openPTY(t)
	p, err := openSerialPort(slave, 9600, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.Close() }()
	if _, err := master.Write([]byte{1, 2, 3, 4}); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	got, err := p.Read(4, 3*time.Second)
	if err != nil || string(got) != "\x01\x02\x03\x04" || time.Since(start) > time.Second {
		t.Errorf("Read = %q %v after %v, want the 4 bytes at once", got, err, time.Since(start))
	}
	// fewer bytes than asked for: they come back once the timeout has elapsed
	_, _ = master.Write([]byte{9})
	start = time.Now()
	got, err = p.Read(4, 150*time.Millisecond)
	if err != nil || string(got) != "\x09" || time.Since(start) < 140*time.Millisecond {
		t.Errorf("short Read = %q %v after %v, want 1 byte after about the timeout", got, err, time.Since(start))
	}
}

// writeNew reports the failure of a write as well as of an open.
func TestWriteNewExisting(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x")
	if err := writeNew(p, []byte("a")); err != nil {
		t.Fatal(err)
	}
	if err := writeNew(p, []byte("b")); err == nil {
		t.Error("second create succeeded")
	}
}
