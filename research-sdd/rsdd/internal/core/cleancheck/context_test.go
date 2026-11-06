package cleancheck

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// wantTimedOut is the typed state of a run the caller's context ended: nothing is claimed, so neither a clean nor the
// findings seen so far may be in the Result.
func wantTimedOut(t *testing.T, w *world, r Result) {
	t.Helper()
	if r.Verdict != TimedOut || r.Exit != 124 || r.Summary != "" || r.Findings != 0 || r.Warnings != 0 ||
		len(r.Absent) != 0 || len(r.Degraded) != 0 || len(r.Lines) != 1 || r.Lines[0].Stream != Err ||
		!strings.HasPrefix(r.Lines[0].Text, "clean-check: ERROR: timed out") {
		t.Fatalf("not the typed timed-out state:\n%s", w.dump(r))
	}
}

func TestCancelledContextIsTimedOut(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.write("stray.txt", "x") // a finding that must not leak into a timed-out result
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	wantTimedOut(t, w, Check(ctx, w.opts()))
}

func TestExpiredDeadlineIsTimedOut(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.write("stray.txt", "x")
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	r := Check(ctx, w.opts())
	wantTimedOut(t, w, r)
	if !strings.Contains(r.Lines[0].Text, context.DeadlineExceeded.Error()) {
		t.Errorf("the line must say why: %q", r.Lines[0].Text)
	}
}

// The context ending in the middle of a run (here: when the clock is read, after the untracked scan found a file) is
// the same typed state, never the findings so far.
func TestContextEndingMidRunIsTimedOut(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.write("stray.txt", "x")
	w.writeAt(w.scratch+"/x.sh", "x")
	cancelled, stop := context.WithCancel(context.Background())
	o := w.opts()
	o.Scratchpad = w.scratch
	o.Now = func() time.Time { stop(); return time.Now() }
	wantTimedOut(t, w, Check(cancelled, o))
}

// A context that is cancelled with no deadline cannot stop the git child (proc has no cancel), but the run ends at
// once with the typed state instead of waiting for it; the blocking git is released at the end of the test.
func TestCancelWithoutDeadlineEndsTheRunPromptly(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	pidFile := w.blockingGit()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		for {
			if _, err := os.Stat(pidFile); err == nil {
				cancel() // git is running: cancel while it blocks
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()
	start := time.Now()
	wantTimedOut(t, w, Check(ctx, w.opts()))
	if took := time.Since(start); took > 4*time.Second {
		t.Errorf("a cancelled run took %v to end", took)
	}
}

func TestAgeDefaults(t *testing.T) {
	if got := (Age{}).or(24); got != 24 {
		t.Errorf("an unset age is the default, got %d", got)
	}
	if got := AgeOf(0).or(24); got != 0 {
		t.Errorf("an explicit 0 is 0, got %d", got)
	}
	if got := AgeOf(5).or(24); got != 5 {
		t.Errorf("an explicit age is kept, got %d", got)
	}
}

func TestNilContextIsATypedRefusal(t *testing.T) {
	w := newWorld(t)
	var none context.Context // nil: the case under test
	r := Check(none, w.opts())
	if r.Exit != 2 || r.Verdict != Refused || r.Summary != "" || !strings.Contains(r.Stderr(), "context") {
		t.Errorf("%s", w.dump(r))
	}
}

// blockingGit puts a git in front of the real one whose first call records its pid and then waits for a marker file
// the test never creates (bounded, so a context that is ignored costs seconds, not minutes).
func (w *world) blockingGit() (pidFile string) {
	w.t.Helper()
	pidFile = w.root + "/git.pid"
	marker := w.root + "/git.release"
	execfile.Write(w.t, w.root+"/bin/git", "#!/bin/sh\necho $$ > "+pidFile+"\ni=0\nwhile [ ! -e "+marker+" ] && [ $i -lt 160 ]; do sleep 0.05; i=$((i+1)); done\nexit 1\n")
	w.t.Cleanup(func() { _ = os.WriteFile(marker, nil, 0o644) })
	w.env = append(w.env, "PATH="+w.root+"/bin:"+os.Getenv("PATH"))
	return pidFile
}

// A deadline that fires while git blocks stops the child promptly and gives the typed state; the child is gone.
func TestDeadlineStopsABlockedGit(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	pidFile := w.blockingGit()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	start := time.Now()
	r := Check(ctx, w.opts())
	wantTimedOut(t, w, r)
	if took := time.Since(start); took > 6*time.Second {
		t.Errorf("the deadline of 2s took %v to stop the run", took)
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatalf("the blocking git never started: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	if !pidGone(pid) {
		t.Errorf("the child %d is still alive after the run", pid)
	}
}
