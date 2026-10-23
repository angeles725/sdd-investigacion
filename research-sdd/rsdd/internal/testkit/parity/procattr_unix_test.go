//go:build unix

package parity

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// spawnGrandchild runs script under execute; the script backgrounds a
// long sleep that inherits the output pipes and writes its pid to a file.
// It returns the outcome, how long execute took and the sleeper's pid.
func spawnGrandchild(t *testing.T, timeout time.Duration, script string) (outcome, time.Duration, int) {
	t.Helper()
	needSh(t)
	dir := t.TempDir()
	r := &Runner{Cfg: Config{Timeout: timeout}}
	start := time.Now()
	o := r.execute("/bin/sh", []string{"-c", script}, []string{"PATH=" + os.Getenv("PATH")}, dir, nil)
	el := time.Since(start)
	b, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		t.Fatalf("grandchild pid not recorded: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	return o, el, pid
}

func alive(pid int) bool {
	return !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}

func TestTimeoutKillsTheWholeProcessGroup(t *testing.T) {
	o, _, pid := spawnGrandchild(t, 300*time.Millisecond, `sleep 30 & echo $! > pid; wait`)
	if !o.timedOut {
		t.Fatalf("want a timeout, got %+v", o)
	}
	deadline := time.Now().Add(5 * time.Second)
	for alive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("grandchild %d survived the timeout kill: the kill must target the process group", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestPipeHeldByAGrandchildIsBoundedByWaitDelay(t *testing.T) {
	// The child exits at once but leaves a sleeper holding stdout: no
	// timeout fires, so only WaitDelay stops the wait for the pipe.
	o, el, _ := spawnGrandchild(t, time.Minute, `sleep 10 & echo $! > pid; exit 0`)
	if el > 6*time.Second {
		t.Fatalf("execute waited %s on a pipe held by a grandchild: WaitDelay must bound it", el)
	}
	if o.timedOut {
		t.Fatalf("no timeout expected: %+v", o)
	}
}
