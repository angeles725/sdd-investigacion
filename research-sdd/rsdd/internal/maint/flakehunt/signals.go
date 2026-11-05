package flakehunt

import (
	"os"
	"os/signal"
	"syscall"
)

// Exit codes of an interrupted hunt (128 + the signal), as the bash EXIT/TERM/INT traps gave.
const (
	exitTerm = 143
	exitInt  = 130
)

// interrupter turns the INT/TERM a hunt receives into an exit code. The source is injected so a test can deliver a
// signal without signalling its own process.
type interrupter struct {
	ch   <-chan os.Signal
	stop func()
	code int // sticky: the first signal wins
}

func newInterrupter(notify func() (<-chan os.Signal, func())) *interrupter {
	if notify == nil {
		return &interrupter{stop: func() {}}
	}
	ch, stop := notify()
	return &interrupter{ch: ch, stop: stop}
}

// realNotify is the process signal source.
func realNotify() (<-chan os.Signal, func()) {
	ch := make(chan os.Signal, 4)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	return ch, func() { signal.Stop(ch) }
}

func (i *interrupter) record(sig os.Signal) {
	if i.code == 0 {
		i.code = exitTerm
		if sig == syscall.SIGINT {
			i.code = exitInt
		}
	}
}

// pending is the exit code of a signal already received (0: none). It never blocks.
func (i *interrupter) pending() int {
	if i.code == 0 {
		select {
		case sig := <-i.ch:
			i.record(sig)
		default:
		}
	}
	return i.code
}

// await waits for done to close and reports whether a signal came first (recording it).
func (i *interrupter) await(done <-chan struct{}) bool {
	select {
	case <-done:
		return false
	case sig := <-i.ch:
		i.record(sig)
		return true
	}
}
