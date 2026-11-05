package prpipeline

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// The gate lock is taken in process, so the bash suite's `flock` shim cases live here: a held lock is the real thing.
func TestGateLockTimeoutIsNotAGateFailure(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	if err := os.MkdirAll(w.Dir+"/st", 0o755); err != nil {
		t.Fatal(err)
	}
	held, err := os.OpenFile(w.Dir+"/st/gate.lock", os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if !kitmaint.Flock(held, 0, time.Sleep) {
		t.Fatal("cannot hold the lock")
	}
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", "--gate-cmd", `echo GATE-RAN >> "$SHIM_STATE/calls.log"`, w.Wt, "7", "b"}, "KIT_GATE_LOCK_TIMEOUT=0")
	if r.rc != 22 || !strings.HasSuffix(r.out, "kit-pr-pipeline: gate-lock-timeout: #7: another gate holds the lock; re-run when it finishes\n") {
		t.Errorf("%+v", r)
	}
	if strings.Contains(w.Calls(), "GATE-RAN") || strings.Contains(w.Calls(), "gh pr checks") {
		t.Errorf("neither the gate nor CI may run: %q", w.Calls())
	}
}

func TestBadLockTimeoutKnobIsAGateUsageError(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, "KIT_GATE_LOCK_TIMEOUT=x")
	if r.rc != 2 || !strings.HasSuffix(r.out, "kit-pr-pipeline: usage: #7: kit-gate.sh rejected its arguments\n") || strings.Contains(w.Calls(), "gh pr checks") {
		t.Errorf("%+v", r)
	}
}
