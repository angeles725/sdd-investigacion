package cleancheck

import (
	"context"
	"os"
	"testing"
	"time"
)

// A context that has ended never starts a child: the call answers 124 at once (the same code a timed-out child gets).
func TestGitOnAnEndedContextStartsNothing(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	r := newRun(context.Background(), w.opts())
	if !r.resolveInputs() {
		t.Fatal(w.dump(r.res))
	}
	pidFile := w.blockingGit()
	r.env = gitEnvironment(w.env) // now with the blocking stub first on PATH
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r.ctx = ctx
	if g := r.git("status"); g.rc != 124 {
		t.Errorf("rc %d, want 124", g.rc)
	}
	time.Sleep(300 * time.Millisecond) // a negative window: a child that wrongly started would have written its pid by now
	if _, err := os.Stat(pidFile); err == nil {
		t.Error("a child was started on an ended context")
	}
}

// A context that is cancelled while git runs gives 124 at once, not the empty success of an unfinished child.
func TestGitCancelledWhileRunningAnswers124(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	r := newRun(context.Background(), w.opts())
	if !r.resolveInputs() {
		t.Fatal(w.dump(r.res))
	}
	pidFile := w.blockingGit()
	r.env = gitEnvironment(w.env) // now with the blocking stub first on PATH
	ctx, cancel := context.WithCancel(context.Background())
	r.ctx = ctx
	go func() {
		for {
			if _, err := os.Stat(pidFile); err == nil {
				cancel()
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()
	if g := r.git("status"); g.rc != 124 {
		t.Errorf("rc %d, want 124", g.rc)
	}
}

// flipCtx reports no error for its first n questions and a cancellation after: a context that ends at a chosen point.
type flipCtx struct {
	context.Context
	n, asked int
}

func (f *flipCtx) Err() error {
	f.asked++
	if f.asked > f.n {
		return context.Canceled
	}
	return nil
}

// loopWorld has scratch scratchpad files and probes files under sources/probes.
func loopWorld(t *testing.T, scratch, probes int) *run {
	t.Helper()
	w := newWorld(t)
	keep(w, "sources/\n")
	for i := range max(scratch, probes) {
		name := "f" + string(rune('a'+i)) + ".txt"
		if i < scratch {
			w.writeAt(w.scratch+"/"+name, name)
		}
		if i < probes {
			w.write("sources/probes/b1/"+name, name)
		}
	}
	w.write("sources/probes/b1/SCRIPTS-MANIFEST.md", "| script | sha256 |\n|---|---|\n")
	r := newRun(context.Background(), w.opts())
	r.o.Scratchpad = w.scratch
	r.settleScratchpad()
	if !r.resolveInputs() || !r.loadKeep() {
		t.Fatal(w.dump(r.res))
	}
	return r
}

// questions counts how often op asks its context whether it ended, for n files, with a context that never does.
func questions(t *testing.T, scratch, probes int, op func(r *run) bool) int {
	t.Helper()
	r := loopWorld(t, scratch, probes)
	f := &flipCtx{Context: context.Background(), n: 1 << 30}
	r.ctx = f
	if !op(r) {
		t.Fatal("the operation failed on a context that never ends")
	}
	return f.asked
}

// Each extra file costs its walk question AND its loop question: a loop that never asks whether the context ended
// would let a cancelled run hash and read every remaining file.
func TestPerFileLoopsAskTheContext(t *testing.T) {
	for name, c := range map[string]struct {
		op            func(r *run) bool
		scratch, more int
	}{
		"scratchpad files": {func(r *run) bool { _, ok := r.scanScratchpad(); return ok }, 1, 0},
		"probes hashing":   {func(r *run) bool { _, ok := r.readProbes(); return ok }, 0, 1},
	} {
		t.Run(name, func(t *testing.T) {
			// only the files of the loop under test grow (the other stays at 2)
			few := questions(t, 2, 2, c.op)
			many := questions(t, 2+3*c.scratch, 2+3*c.more, c.op)
			if many-few < 2*3 {
				t.Errorf("3 more files cost %d more questions, want at least 6 (one in the walk, one in the loop)", many-few)
			}
		})
	}
}
