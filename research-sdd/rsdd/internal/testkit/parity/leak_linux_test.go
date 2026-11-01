//go:build linux

package parity

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// pidGone reports whether pid no longer runs (a zombie awaiting reaping counts as gone).
func pidGone(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return true
	}
	i := strings.LastIndexByte(string(b), ')')
	return i >= 0 && i+2 < len(b) && b[i+2] == 'Z'
}

func TestSetsidGrandchildIsReapedAndReported(t *testing.T) {
	if _, err := exec.LookPath("setsid"); err != nil {
		t.Skip("setsid not available")
	}
	r := newRig(t)
	pidFile := filepath.Join(t.TempDir(), "sleeper.pid")
	pid := 0
	t.Cleanup(func() { // kill only the recorded pid, and only if still alive
		if pid > 0 && !pidGone(pid) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	res, _ := r.run([]string{"leak=" + pidFile}, []string{"out="}, nil)
	if b, err := os.ReadFile(pidFile); err == nil {
		pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
	}
	if pid <= 0 {
		t.Fatalf("the side did not record the sleeper pid (%s)", joined(res.Problems))
	}
	if res.Status != StatusFailed || !hasKind(res.Problems, KindLeaked) {
		t.Fatalf("a setsid grandchild must be reported as %s: %s %s", KindLeaked, res.Status, joined(res.Problems))
	}
	if !strings.Contains(joined(res.Problems), strconv.Itoa(pid)) {
		t.Fatalf("the problem must name the leaked pid %d: %s", pid, joined(res.Problems))
	}
	for i := 0; i < 100 && !pidGone(pid); i++ {
		time.Sleep(50 * time.Millisecond)
	}
	if !pidGone(pid) {
		t.Fatalf("the leaked sleeper %d survived the run", pid)
	}
}

func TestCleanRunReportsNoLeak(t *testing.T) {
	r := newRig(t)
	res, _ := r.run([]string{"out=a"}, []string{"out=a"}, nil)
	if res.Status != StatusEqual || hasKind(res.Problems, KindLeaked) {
		t.Fatalf("%s %s", res.Status, joined(res.Problems))
	}
}

func TestLeakDoesNotHideTimeout(t *testing.T) {
	if _, err := exec.LookPath("setsid"); err != nil {
		t.Skip("setsid not available")
	}
	r := newRig(t)
	r.runner.Cfg.Timeout = 300 * time.Millisecond
	pidFile := filepath.Join(t.TempDir(), "sleeper.pid")
	pid := 0
	t.Cleanup(func() {
		if pid > 0 && !pidGone(pid) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	res, _ := r.run([]string{"leak=" + pidFile, "sleep=30"}, []string{"out="}, nil)
	if b, err := os.ReadFile(pidFile); err == nil {
		pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
	}
	if !hasKind(res.Problems, KindLeaked) || !hasKind(res.Problems, KindTimeout) {
		t.Fatalf("a timed-out run that also leaked must report both %s and %s: %s", KindTimeout, KindLeaked, joined(res.Problems))
	}
}
