//go:build unix

package parity

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// spawnGrandchild runs script under execute; the script records its own
// process group in a file (the child leads its group: Setpgid) and backgrounds
// a long sleep in that group that inherits the output pipes. It returns the
// outcome, how long execute took and the recorded group. Cleanup goes through
// the killGroup guard on that group, never a raw pid: the sleeper may already
// be reaped and its pid reused by an unrelated process.
func spawnGrandchild(t *testing.T, timeout time.Duration, script string) (outcome, time.Duration, int) {
	t.Helper()
	needSh(t)
	dir := t.TempDir()
	r := &Runner{Cfg: Config{Timeout: timeout}}
	start := time.Now()
	o := r.execute("/bin/sh", []string{"-c", "echo $$ > pgid; " + script}, []string{"PATH=" + os.Getenv("PATH")}, dir, nil)
	el := time.Since(start)
	b, err := os.ReadFile(filepath.Join(dir, "pgid"))
	if err != nil {
		t.Fatalf("child group not recorded: %v", err)
	}
	pgid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = killGroup(pgid, pgid) })
	return o, el, pgid
}

func TestTimeoutKillsTheWholeProcessGroup(t *testing.T) {
	o, _, pgid := spawnGrandchild(t, 300*time.Millisecond, `sleep 30 & wait`)
	if !o.timedOut {
		t.Fatalf("want a timeout, got %+v", o)
	}
	deadline := time.Now().Add(5 * time.Second)
	for groupAlive(pgid) {
		if time.Now().After(deadline) {
			t.Fatalf("group %d survived the timeout kill: the kill must target the process group", pgid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestPipeHeldByAGrandchildIsBoundedByWaitDelay(t *testing.T) {
	// The child exits at once but leaves a sleeper holding stdout: no
	// timeout fires, so only WaitDelay stops the wait for the pipe.
	o, el, _ := spawnGrandchild(t, time.Minute, `sleep 10 & exit 0`)
	if el > 6*time.Second {
		t.Fatalf("execute waited %s on a pipe held by a grandchild: WaitDelay must bound it", el)
	}
	if o.timedOut {
		t.Fatalf("no timeout expected: %+v", o)
	}
}
