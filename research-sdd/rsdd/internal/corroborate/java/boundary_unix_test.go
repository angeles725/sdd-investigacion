//go:build unix

package java

import (
	"testing"
	"time"
)

// Boundary pins for runAdapter (kit issue #2534). They use a real clock and real child processes, no Bubblewrap.

// realClockEnv is runnerEnv with a wall clock, so durations are observable.
func realClockEnv(t *testing.T) (*env, string) {
	t.Helper()
	e, root := runnerEnv(t)
	e.s.Clock = time.Now
	return e, root
}

// The cleanup deadline is the timeout less a 250 ms margin, so a child that ends at 0.88 s of a 1 s budget is cut
// (a margin that is added, or lost, lets it finish).
func TestCleanupMarginIsSubtractedFromThePositiveTimeout(t *testing.T) {
	e, root := realClockEnv(t)
	out, err := e.runAdapter(sh("sleep 0.95"), root, root, baseEnv, 1, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "timeout" {
		t.Errorf("status = %q, want timeout: the run is stopped at 0.75 s", out.status)
	}
	if out.durationMS >= 950 {
		t.Errorf("duration = %d ms, want the stop before the child's own end", out.durationMS)
	}
}

// The margin is a quarter of the timeout at most; the formula is pinned on a negative budget too, where the cleanup
// deadline is already past and a margin that grew with the timeout would put it in the future.
func TestCleanupMarginIsAQuarterOfTheTimeoutAtMost(t *testing.T) {
	e, root := realClockEnv(t)
	out, err := e.runAdapter(sh("sleep 0.5"), root, root, baseEnv, -1, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "timeout" {
		t.Errorf("status = %q, want timeout on an expired budget", out.status)
	}
}

// Caps are exceeded only past their value: a child that sits exactly on a cap is a success, whether it is still
// running when the cap is polled or has already ended.
func TestAdapterOnTheCapsExactlyIsNotCapExceeded(t *testing.T) {
	cases := []struct {
		name             string
		script           string
		maxFiles, maxByt int64
	}{
		// stdout.raw.txt and stderr.raw.txt count as files: 2 + f == 3.
		{"file count while running", "echo x > f; sleep 0.4", 3, 4096},
		{"file count after exit", "echo x > f", 3, 4096},
		{"byte count while running", "printf 12345 > f; sleep 0.4", 10, 5},
		{"byte count after exit", "printf 12345 > f", 10, 5},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, root := runnerEnv(t)
			e.helper = nil // no RLIMIT_FSIZE: the cap polling is what is under test
			out, err := e.runAdapter(sh(c.script), root, root, baseEnv, 5, c.maxFiles, c.maxByt)
			if err != nil {
				t.Fatal(err)
			}
			if out.status != "success" || out.diagnosticsTruncated {
				t.Errorf("outcome = %+v, want success", out)
			}
		})
	}
	// One past either cap is still a cap_exceeded run.
	e, root := runnerEnv(t)
	e.helper = nil
	if out, err := e.runAdapter(sh("echo xx > f; echo y > g"), root, root, baseEnv, 5, 3, 4096); err != nil || out.status != "cap_exceeded" {
		t.Errorf("file cap: %+v %v", out, err)
	}
	e, root = runnerEnv(t)
	e.helper = nil
	if out, err := e.runAdapter(sh("printf 123456 > f"), root, root, baseEnv, 5, 10, 5); err != nil || out.status != "cap_exceeded" {
		t.Errorf("byte cap: %+v %v", out, err)
	}
}
