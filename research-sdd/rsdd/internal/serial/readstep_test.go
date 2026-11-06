//go:build linux

package serial

import (
	"syscall"
	"testing"
	"time"
)

// readStep is one rc.Read callback call (issue #2732): the level-triggered poll comes first on a later call,
// and nothing is read on a stale wake.
func TestReadStep(t *testing.T) {
	for _, c := range []struct {
		name       string
		calls      int
		readable   bool
		readGot    int
		readErr    error
		wantDone   bool
		wantGot    int
		wantErr    error
		wantReads  int
		wantPolled int
	}{
		{"first call, empty: no data yet, readable not consulted", 1, true, 0, nil, false, 0, nil, 1, 0},
		{"first call, EAGAIN: wait", 1, true, 0, syscall.EAGAIN, false, 0, syscall.EAGAIN, 1, 0},
		{"first call, data: done", 1, false, 3, nil, true, 3, nil, 1, 0},
		{"later call, stale wake: not readable, no read", 2, false, 5, nil, false, 0, nil, 0, 1},
		{"later call, readable, data: done (byte landed after an empty look)", 2, true, 4, nil, true, 4, nil, 1, 1},
		{"later call, readable, empty: the disconnect", 2, true, 0, nil, true, 0, nil, 1, 1},
		{"later call, readable, error: done with the error", 2, true, 0, syscall.EIO, true, 0, syscall.EIO, 1, 1},
		{"later call, readable, EAGAIN: wait", 2, true, 0, syscall.EAGAIN, false, 0, syscall.EAGAIN, 1, 1},
	} {
		reads, polls := 0, 0
		got, err, done := readStep(c.calls,
			func() bool { polls++; return c.readable },
			func() (int, error) { reads++; return c.readGot, c.readErr })
		if done != c.wantDone || got != c.wantGot || err != c.wantErr || reads != c.wantReads || polls != c.wantPolled {
			t.Errorf("%s: got=%d err=%v done=%v reads=%d polls=%d, want got=%d err=%v done=%v reads=%d polls=%d",
				c.name, got, err, done, reads, polls, c.wantGot, c.wantErr, c.wantDone, c.wantReads, c.wantPolled)
		}
	}
}

// fdReadable follows the level of the descriptor, not an edge.
func TestFdReadableOnPTY(t *testing.T) {
	master, slave := openPTY(t)
	p, err := openSerialPort(slave, 9600, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.Close() }()
	fd := int(p.(*ttyPort).f.Fd())
	if fdReadable(fd) {
		t.Error("idle port reported readable")
	}
	if _, err := master.Write([]byte{7}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !fdReadable(fd) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !fdReadable(fd) {
		t.Error("port with a queued byte never reported readable")
	}
}

// Real data that arrives after a wait is returned whole; a short read returns the partial bytes with a nil error.
func TestTTYReadAfterWaitAndPartial(t *testing.T) {
	master, slave := openPTY(t)
	p, err := openSerialPort(slave, 9600, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.Close() }()
	go func() {
		time.Sleep(50 * time.Millisecond)
		_, _ = master.Write([]byte{5, 6})
	}()
	got, err := p.Read(2, 3*time.Second)
	if err != nil || string(got) != "\x05\x06" {
		t.Errorf("Read after wait = %q %v, want 2 bytes", got, err)
	}
	_, _ = master.Write([]byte{8})
	got, err = p.Read(4, 100*time.Millisecond)
	if err != nil || string(got) != "\x08" {
		t.Errorf("partial Read = %q %v, want the 1 byte and a nil error", got, err)
	}
}
