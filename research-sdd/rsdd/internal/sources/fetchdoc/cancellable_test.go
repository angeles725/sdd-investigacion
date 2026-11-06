package fetchdoc

import (
	"context"
	"os"
	"syscall"
	"testing"
)

// A signal that arrived before a stage must stop the run there: the stage is not started at all, whatever it
// would have done with a cancelled context.
func TestCancellableStartsNoStageAfterASignal(t *testing.T) {
	for _, tc := range []struct {
		sig  os.Signal
		code int
	}{{syscall.SIGINT, exitInterrupted}, {syscall.SIGTERM, exitTerminated}} {
		sigs := make(chan os.Signal, 1)
		s := newSession(sigs)
		sigs <- tc.sig
		<-s.ctx.Done()
		x := &exe{sess: s}
		started := false
		code, cut := x.cancellable(func(context.Context) int { started = true; return 0 })
		s.Close()
		if started || !cut || code != tc.code {
			t.Errorf("%v: started=%v cut=%v code=%d, want no stage, cut, %d", tc.sig, started, cut, code, tc.code)
		}
	}
}

func TestCancellableReturnsTheStageStatusWhenNothingInterrupted(t *testing.T) {
	s := newSession(nil)
	defer s.Close()
	x := &exe{sess: s}
	if code, cut := x.cancellable(func(context.Context) int { return 7 }); code != 7 || cut {
		t.Errorf("code=%d cut=%v, want 7 and not cut", code, cut)
	}
}
