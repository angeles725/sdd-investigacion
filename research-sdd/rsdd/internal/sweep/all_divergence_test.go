//go:build unix

package sweep

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The declared differences of `sweep all` from sweep-all.sh (L4 of odd/tasks/sweep-all-go.md, the table of
// tool-registry.d/sweep-all.md). They have no oracle: the script did the other thing, which is the defect. Every
// one runs real stub scripts through core/proc (no host tool is probed for, no test skips), each with a short
// bound and a stub that outlives it.

// A script that exits 124 is a script that failed, not one that timed out.
func TestAllExit124IsNotATimeout(t *testing.T) {
	w := newWorld(t)
	w.stubs(map[string]int{allNames[1]: 124})
	r := w.runAll()
	if r.rc != 1 || !strings.Contains(r.out, "\nFAIL  "+allNames[1]+" (exit 124)\n") || strings.Contains(r.out, "timed out") {
		t.Errorf("rc=%d\n%s", r.rc, r.out)
	}
}

// A script killed by a signal says so, instead of the shell's 128+N.
func TestAllSignalKilledScript(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	w.stub(allNames[1], "kill -KILL $$")
	r := w.runAll()
	if r.rc != 1 || !strings.Contains(r.out, "\nFAIL  "+allNames[1]+" (killed by signal 9)\n") || !strings.Contains(r.out, "  FAIL  "+allNames[1]+" (signal 9)\n") {
		t.Errorf("rc=%d\n%s", r.rc, r.out)
	}
}

// A script that ignores SIGTERM is killed once the grace period is over; `timeout` sent TERM and waited for ever.
// The script records its PID, and the test proves it (and so its group) is gone when the aggregator returns.
func TestAllTermIgnoringScriptIsKilled(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	w.env["RSDD_SWEEP_TIMEOUT"] = "0.3"
	pidFile := w.root + "/term.pid"
	w.stub(allNames[1], "trap '' TERM\necho $$ > '"+pidFile+"'\nwhile :; do sleep 0.05; done")
	start := time.Now()
	r := w.runAll()
	if took := time.Since(start); took > 10*time.Second {
		t.Errorf("the aggregator took %v: the stuck script was not killed", took)
	}
	if r.rc != 1 || !strings.Contains(r.out, "\nFAIL  "+allNames[1]+" (timed out after 0.3s)\n") || !strings.Contains(r.out, "PASS  "+allNames[7]+"\n") {
		t.Errorf("rc=%d\n%s", r.rc, r.out)
	}
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatalf("the stub never ran: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, 0); err == nil {
		_ = syscall.Kill(pid, syscall.SIGKILL) // never leave the stuck script behind, by its recorded PID
		t.Errorf("script %d is still alive after the aggregator returned", pid)
	}
}

// A script that floods its output is stopped at the bound: the flood is cut, and the failure names the bound.
func TestAllOutputIsBounded(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	w.stub(allNames[1], "head -c 5000 /dev/zero | tr '\\0' x\necho")
	r := w.runWith(allConfig{run: proc.Run, maxBytes: 300})
	if r.rc != 1 || !strings.Contains(r.out, "\nFAIL  "+allNames[1]+" (output exceeded 300 bytes)\n") || !strings.Contains(r.out, "  FAIL  "+allNames[1]+" (output cap)\n") {
		t.Errorf("rc=%d\n%.600s", r.rc, r.out)
	}
	if !strings.Contains(r.out, banner(allNames[1])+strings.Repeat("x", 300)+"\nFAIL") {
		t.Errorf("the flood was not cut at exactly the 300 bound bytes\n%.600s", r.out)
	}
	if !strings.Contains(r.out, "PASS  "+allNames[7]+"\n") {
		t.Errorf("the scripts after the flood did not run\n%.600s", r.out)
	}
}

// A shell that cannot be started is a typed banner for every script, and the run still reaches the summary.
func TestAllUnstartableShell(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	w.env["PATH"] = w.root + "/no-such-bin"
	r := w.runAll()
	if r.rc != 1 {
		t.Errorf("rc=%d", r.rc)
	}
	if n := strings.Count(r.out, " (cannot start: "); n != 8 {
		t.Errorf("%d cannot-start banners, want 8\n%s", n, r.out)
	}
	if !strings.Contains(r.out, "  FAIL  "+allNames[7]+" (cannot start)\n") {
		t.Errorf("no summary line for the last script\n%s", r.out)
	}
}

// Stdout and stderr keep their order even when the script writes a lot of both (the streams share one pipe).
func TestAllStreamsStayInOrder(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	w.stub(allNames[1], "for i in 1 2 3 4 5 6 7 8 9 10; do echo \"out$i\"; echo \"err$i\" >&2; done")
	r := w.runAll()
	var want strings.Builder
	for i := 1; i <= 10; i++ {
		want.WriteString("out" + strconv.Itoa(i) + "\nerr" + strconv.Itoa(i) + "\n")
	}
	if !strings.Contains(r.out, banner(allNames[1])+want.String()+"\nPASS  ") || r.err != "" {
		t.Errorf("order lost\nstdout:\n%s\nstderr:%q", r.out, r.err)
	}
}
