package fetchdoc

import (
	"os"
	"syscall"
	"testing"
)

// A signal that reached the channel before Block is never lost: Block settles it, so the check that follows sees it.
func TestBlockSettlesASignalQueuedBeforeIt(t *testing.T) {
	for i := 0; i < 300; i++ {
		sigs := make(chan os.Signal, 2)
		s := newSession(sigs)
		sigs <- syscall.SIGTERM
		s.Block()
		c, ok := s.interrupted()
		s.Close()
		if !ok || c != exitTerminated {
			t.Fatalf("round %d: a TERM queued before Block was lost (code %d, interrupted %v)", i, c, ok)
		}
	}
}

func TestBlockedSessionIgnoresLaterSignals(t *testing.T) {
	sigs := make(chan os.Signal, 2)
	s := newSession(sigs)
	defer s.Close()
	s.Block()
	sigs <- syscall.SIGINT
	sigs <- syscall.SIGTERM
	s.Block() // a second Block settles the queue again and must not wake the earlier signals
	if c, ok := s.interrupted(); ok {
		t.Errorf("a signal after Block was recorded (code %d)", c)
	}
	if s.ctx.Err() != nil {
		t.Error("a signal after Block cancelled the run")
	}
}

func TestBlockAfterCloseDoesNotHang(t *testing.T) {
	s := newSession(nil)
	s.Close()
	s.Block()
	if _, ok := s.interrupted(); ok {
		t.Error("no signal was sent")
	}
}

func TestSIGINTIsExit130(t *testing.T) {
	sigs := make(chan os.Signal, 1)
	s := newSession(sigs)
	defer s.Close()
	sigs <- syscall.SIGINT
	<-s.ctx.Done()
	if c, _ := s.interrupted(); c != exitInterrupted {
		t.Errorf("code %d", c)
	}
}
