//go:build linux

package carve

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func launch(t *testing.T, script string, timeout time.Duration, procs int, memory uint64) error {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return launchWorker(launchSpec{argv: []string{"/bin/sh", "-c", script}, dir: t.TempDir(), self: self, timeout: timeout, maxProcs: procs, memory: memory, now: time.Now})
}

const roomyMemory = 8 << 30 // the Go test binary that serves the re-exec helper needs address space of its own

func TestLaunchedWorkerThatExitsZeroSucceeds(t *testing.T) {
	if err := launch(t, "exit 0", 5*time.Second, 4, roomyMemory); err != nil {
		t.Fatal(err)
	}
}

func TestLaunchedWorkerFailureCarriesItsStderr(t *testing.T) {
	err := launch(t, "echo 'firmware-carve: boom' >&2; exit 3", 5*time.Second, 4, roomyMemory)
	if err == nil || err.Error() != "isolated worker failed: firmware-carve: boom" {
		t.Errorf("err = %v", err)
	}
	if err := launch(t, "exit 1", 5*time.Second, 4, roomyMemory); err == nil || err.Error() != "isolated worker failed" {
		t.Errorf("a silent failure: err = %v", err)
	}
}

func TestLaunchedWorkerStderrIsCutAtFourKiB(t *testing.T) {
	err := launch(t, "head -c 100000 /dev/zero | tr '\\0' x >&2; exit 1", 5*time.Second, 4, roomyMemory)
	if err == nil || len(err.Error()) != len("isolated worker failed: ")+4096 {
		t.Errorf("err length = %d, want the prefix plus 4096 bytes", len(err.Error()))
	}
}

func TestLaunchedWorkerIsBoundedInTime(t *testing.T) {
	start := time.Now()
	err := launch(t, "sleep 5", 100*time.Millisecond, 4, roomyMemory)
	if err == nil || err.Error() != "timeout" {
		t.Errorf("err = %v, want timeout", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("a 100 ms bound took %v", time.Since(start))
	}
}

func TestLaunchedWorkerProcessTreeIsCappedAndCleaned(t *testing.T) {
	t.Parallel() // waits on real timers; overlapping them keeps the teeth run inside the CI job cap
	leak := filepath.Join(t.TempDir(), "LEAK")
	err := launch(t, "(sleep 0.5; touch '"+leak+"') & sleep 3", 5*time.Second, 0, roomyMemory)
	if err == nil || err.Error() != "process cap" {
		t.Fatalf("err = %v, want process cap", err)
	}
	time.Sleep(900 * time.Millisecond)
	if _, err := os.Stat(leak); err == nil {
		t.Error("a background child outlived the process cap")
	}
}

func TestLaunchedWorkerRunsUnderTheAddressSpaceLimit(t *testing.T) {
	// ulimit -v is in KiB: the worker tree must see exactly the limit it was launched with.
	err := launch(t, `test "$(ulimit -v)" = 1048576 && test "$(ulimit -c)" = 0`, 5*time.Second, 4, 1<<30)
	if err != nil {
		t.Errorf("the limits are not applied to the worker: %v", err)
	}
}

func TestLaunchOfAMissingProgramIsAnError(t *testing.T) {
	err := launchWorker(launchSpec{argv: []string{"/nonexistent/bwrap"}, dir: t.TempDir(), self: "/nonexistent/rsdd", timeout: time.Second, maxProcs: 4, memory: 1 << 30, now: time.Now})
	if err == nil || strings.Contains(err.Error(), "isolated worker failed") {
		t.Errorf("err = %v, want a start failure", err)
	}
}

func TestProcessTreeCountsTheRootAndItsDescendants(t *testing.T) {
	if n := processTree(os.Getpid()); n < 1 {
		t.Errorf("processTree(self) = %d, want at least the process itself", n)
	}
	if n := processTree(1 << 30); n != 0 {
		t.Errorf("processTree of a pid that does not exist = %d, want 0", n)
	}
}
