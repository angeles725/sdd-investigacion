package cleancheck

import (
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// stopped reports that the caller's context ended: the walks and loops return at the next entry, and Check turns
// whatever they left into the typed timed-out state.
func (r *run) stopped() bool { return r.ctx.Err() != nil }

// timedOut is the whole Result of a run the context ended. Nothing the run saw is kept (no finding, no absent or
// degraded kind, no summary): a clean or a partial list must never be taken for a complete answer.
func (r *run) timedOut() Result {
	line := "clean-check: ERROR: timed out: " + r.ctx.Err().Error() + "; nothing was measured completely"
	return Result{Verdict: TimedOut, Exit: 124, Lines: []Line{{Err, line}}}
}

// childTimeout is how long one child may run: the ceiling, or less when the context has a nearer deadline (the child
// is then stopped by its own timeout, process group and all). ok is false when the context is already over (a deadline that passes after this check yields a timeout <= 0, which proc refuses, and Check reports the ended context anyway).
func (r *run) childTimeout() (d time.Duration, ok bool) {
	if r.stopped() {
		return 0, false
	}
	d = kitmaint.ChildCeiling
	if dl, has := r.ctx.Deadline(); has {
		d = min(d, time.Until(dl))
	}
	return d, true
}

// child is one finished bounded run.
type child struct {
	out proc.Result
	err error
}

// runChild runs spec with its timeout cut to the context's deadline. A context that can be cancelled but has no
// deadline cannot stop the child itself (proc has no cancel), so the wait ends at once and ok is false; the child is
// left to its own timeout, which this package bounds at the ceiling. A deadline needs no such shortcut: proc stops the
// child, process group and all, when it passes, and the wait is for that.
func (r *run) runChild(spec proc.Spec) (c child, ok bool) {
	spec.Timeout, ok = r.childTimeout()
	if !ok {
		return child{}, false
	}
	done := make(chan child, 1)
	go func() {
		out, err := proc.Run(spec)
		done <- child{out, err}
	}()
	if _, bounded := r.ctx.Deadline(); bounded {
		return <-done, true
	}
	select {
	case c = <-done:
		return c, true
	case <-r.ctx.Done():
		return child{}, false
	}
}
