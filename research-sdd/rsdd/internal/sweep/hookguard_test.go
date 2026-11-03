package sweep

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// A panic inside a sweep hook must still reach the session as the could-not-run envelope (CLAUDE.md §7, kit issue
// #2610): without the hook's own guard it escapes to cli.Run's recover, which writes to stderr, and the
// SessionStart hook says nothing. The seam is the clock: both sweeps read it right after the kit's TARGETS.md
// resolved to usable paths, so the panic is always reached.

func panicClock() time.Time { panic("boom in the sweep") }

func TestRetrosHookPanicStillEmitsEnvelope(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.targets(a)
	var out, errb bytes.Buffer
	s := w.stdio(&out, &errb)
	s.Clock = panicClock
	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("the panic escaped the hook: %v", p)
			}
		}()
		if rc := runRetrosHook(options{kit: w.kit, hook: true}, s); rc != 0 {
			t.Fatalf("rc=%d, want 0 (a hook never fails the session)", rc)
		}
	}()
	ctx := decodeContext(t, out.String())
	if !strings.HasPrefix(ctx, "Research-SDD retro sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n") || !strings.Contains(ctx, "rsdd: internal-error: boom in the sweep") {
		t.Errorf("context %q", ctx)
	}
}

func TestAuditsHookPanicStillEmitsEnvelope(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.targets(a)
	var out, errb bytes.Buffer
	s := w.stdio(&out, &errb)
	s.Clock = panicClock
	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("the panic escaped the hook: %v", p)
			}
		}()
		if rc := runAuditsHook(options{kit: w.kit, hook: true}, s); rc != 0 {
			t.Fatalf("rc=%d, want 0 (a hook never fails the session)", rc)
		}
	}()
	ctx := decodeContext(t, out.String())
	if !strings.HasPrefix(ctx, "Research-SDD audits sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n") || !strings.Contains(ctx, "rsdd: internal-error: boom in the sweep") {
		t.Errorf("context %q", ctx)
	}
}
