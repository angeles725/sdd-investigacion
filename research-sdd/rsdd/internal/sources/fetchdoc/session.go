package fetchdoc

import (
	"context"
	"os"
	"sync/atomic"
	"syscall"
)

// Exit statuses of a cancelled run: 128 + the signal number, as a shell reports them.
const (
	exitInterrupted = 130
	exitTerminated  = 143
)

// session turns INT/TERM into context cancellation, so the tracked child (and its process group) is stopped, and
// into the run's exit status. From Block on, signals are ignored: from the install of new bytes to the written
// row a signal must never leave bytes without a row (the window is only the install, the sha256 and the row
// write, never a download or a conversion, so the run completes consistently).
type session struct {
	ctx     context.Context
	cancel  context.CancelFunc
	code    atomic.Int32
	blocked atomic.Bool
	done    chan struct{}
}

// newSession starts listening on sigs (nil: no signals). Close ends the listener.
func newSession(sigs <-chan os.Signal) *session {
	ctx, cancel := context.WithCancel(context.Background())
	s := &session{ctx: ctx, cancel: cancel, done: make(chan struct{})}
	go s.listen(sigs)
	return s
}

func (s *session) listen(sigs <-chan os.Signal) {
	for {
		select {
		case sg := <-sigs:
			if s.blocked.Load() {
				continue
			}
			code := int32(exitTerminated)
			if sg == syscall.SIGINT {
				code = exitInterrupted
			}
			s.code.CompareAndSwap(0, code)
			s.cancel()
		case <-s.done:
			return
		}
	}
}

// Close stops the listener and releases the context.
func (s *session) Close() {
	close(s.done)
	s.cancel()
}

// Block makes every later signal a no-op.
func (s *session) Block() { s.blocked.Store(true) }

// interrupted is the exit status of the signal that cancelled the run, when one did.
func (s *session) interrupted() (int, bool) {
	c := s.code.Load()
	return int(c), c != 0
}
