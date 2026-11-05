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
// row a signal must never leave bytes without a row (the window is only the install and the row write, never a
// download or a conversion, so the run completes consistently).
//
// One goroutine handles every signal and the Block request, in order, so a signal that reached the channel before
// Block is recorded before Block returns: the caller checks interrupted() right after Block and a signal is never
// lost between its last check and Block.
type session struct {
	ctx     context.Context
	cancel  context.CancelFunc
	code    atomic.Int32
	blocked atomic.Bool
	freeze  chan chan struct{}
	done    chan struct{}
}

// newSession starts listening on sigs (nil: no signals). Close ends the listener.
func newSession(sigs <-chan os.Signal) *session {
	ctx, cancel := context.WithCancel(context.Background())
	s := &session{ctx: ctx, cancel: cancel, freeze: make(chan chan struct{}), done: make(chan struct{})}
	go s.listen(sigs)
	return s
}

func (s *session) listen(sigs <-chan os.Signal) {
	for {
		select {
		case sg := <-sigs:
			s.record(sg)
		case ack := <-s.freeze:
			for drained := false; !drained; {
				select {
				case sg := <-sigs:
					s.record(sg)
				default:
					drained = true
				}
			}
			s.blocked.Store(true)
			close(ack)
		case <-s.done:
			return
		}
	}
}

// record notes the first signal's exit status and cancels the run, unless signals are already ignored.
func (s *session) record(sg os.Signal) {
	if s.blocked.Load() {
		return
	}
	code := int32(exitTerminated)
	if sg == syscall.SIGINT {
		code = exitInterrupted
	}
	s.code.CompareAndSwap(0, code)
	s.cancel()
}

// Close stops the listener and releases the context.
func (s *session) Close() {
	close(s.done)
	s.cancel()
}

// Block settles every signal already delivered, then makes every later signal a no-op. The caller checks
// interrupted() after it: a signal that arrived before Block is reported, one that arrives after is ignored.
func (s *session) Block() {
	ack := make(chan struct{})
	select {
	case s.freeze <- ack:
		<-ack
	case <-s.done:
		s.blocked.Store(true)
	}
}

// interrupted is the exit status of the signal that cancelled the run, when one did.
func (s *session) interrupted() (int, bool) {
	c := s.code.Load()
	return int(c), c != 0
}
