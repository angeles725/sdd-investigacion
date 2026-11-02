//go:build unix

package java

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// runnerEnv is the env of a test that drives runAdapter directly; the helper is the test binary (TestMain).
func runnerEnv(t *testing.T) (*env, string) {
	t.Helper()
	h := newHarness(t)
	e := newEnv(h.stdio(nil, nil))
	e.helper = os.Executable
	root := filepath.Join(h.root, "engine")
	if err := os.MkdirAll(filepath.Join(root, "output"), 0o755); err != nil {
		t.Fatal(err)
	}
	return e, root
}

func sh(script string) []string { return []string{"/bin/sh", "-c", script} }

var baseEnv = []string{"PATH=/usr/bin:/bin"}

func TestAdapterExitCodeDecidesSuccessOrFailure(t *testing.T) {
	e, root := runnerEnv(t)
	for rc, want := range map[int]string{0: "success", 3: "failed"} {
		out, err := e.runAdapter(sh("echo hi; exit "+strconv.Itoa(rc)), root, root, baseEnv, 5, 10, 4096)
		if err != nil {
			t.Fatal(err)
		}
		if out.status != want || out.returncode != rc || out.diagnosticsTruncated {
			t.Errorf("exit %d: %+v, want status %s", rc, out, want)
		}
		if out.startedAt != "2026-01-02T03:04:05Z" || out.endedAt != out.startedAt || out.durationMS != 0 {
			t.Errorf("timestamps come from the injected clock only: %+v", out)
		}
	}
	got, _ := os.ReadFile(filepath.Join(root, "stdout.raw.txt"))
	if string(got) != "hi\n" {
		t.Errorf("stdout.raw.txt = %q", got)
	}
}

func TestAdapterIsStoppedAtTheTimeoutMinusTheCleanupMargin(t *testing.T) {
	e, root := runnerEnv(t)
	start := time.Now()
	out, err := e.runAdapter(sh("sleep 30"), root, root, baseEnv, 1, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "timeout" || out.returncode >= 0 {
		t.Fatalf("outcome = %+v, want a timeout that ended in a signal", out)
	}
	if el := time.Since(start); el > 2500*time.Millisecond {
		t.Errorf("stopping took %v", el)
	}
}

func TestDescendantsHoldingThePipesAreKilledWithinTheDeadline(t *testing.T) {
	e, root := runnerEnv(t)
	pidFile := filepath.Join(root, "child.pid")
	start := time.Now()
	out, err := e.runAdapter(sh(`(trap '' TERM; sleep 30) & echo $! > child.pid; exit 0`), root, root, baseEnv, 1, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "success" || time.Since(start) > 1500*time.Millisecond {
		t.Fatalf("outcome %+v after %v", out, time.Since(start))
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
	for i := 0; i < 100; i++ {
		stat, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
		if err != nil || strings.Fields(string(stat))[2] == "Z" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("descendant %d survived the group stop", pid)
}

func TestFileSizeLimitStopsAMillionByteWriteAtTheCap(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`trap '' XFSZ; head -c 1048576 /dev/zero > output/million.bin 2>/dev/null; echo $?`), root, root, baseEnv, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(root, "output", "million.bin"))
	if err != nil || fi.Size() != 4096 {
		t.Fatalf("generated file: %v, %v; RLIMIT_FSIZE must cut it at 4096 bytes", fi, err)
	}
	if out.returncode != 0 {
		t.Errorf("outcome = %+v", out)
	}
}

func TestFileCountCapStopsTheRunEarly(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`for i in 1 2 3 4 5 6; do : > output/f$i; done; sleep 30`), root, root, baseEnv, 5, 3, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "cap_exceeded" || out.returncode >= 0 {
		t.Fatalf("outcome = %+v, want cap_exceeded after a stop", out)
	}
}

func TestByteCapOnGeneratedFilesStopsTheRun(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`head -c 3000 /dev/zero > output/a; head -c 3000 /dev/zero > output/b; sleep 30`), root, root, baseEnv, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "cap_exceeded" {
		t.Fatalf("outcome = %+v", out)
	}
}

func TestDiagnosticOverflowIsTruncatedAndCapExceeded(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`head -c 100000 /dev/zero; head -c 100000 /dev/zero >&2; exit 0`), root, root, baseEnv, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "cap_exceeded" || !out.diagnosticsTruncated {
		t.Fatalf("outcome = %+v", out)
	}
	var total int64
	for _, n := range []string{"stdout.raw.txt", "stderr.raw.txt"} {
		fi, err := os.Stat(filepath.Join(root, n))
		if err != nil {
			t.Fatal(err)
		}
		total += fi.Size()
	}
	if total > 4096 {
		t.Errorf("retained %d diagnostic bytes, cap is 4096", total)
	}
}

func TestExactlyFillingTheDiagnosticBudgetIsNotAnOverflow(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`head -c 4096 /dev/zero`), root, root, baseEnv, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "success" || out.diagnosticsTruncated {
		t.Fatalf("outcome = %+v: a chunk that exactly consumes the budget is not an overflow", out)
	}
}

func TestSymlinkEmittedByTheAdapterIsAFailureAndTheGroupIsStopped(t *testing.T) {
	e, root := runnerEnv(t)
	start := time.Now()
	_, err := e.runAdapter(sh(`ln -s /etc/passwd output/l; sleep 30`), root, root, baseEnv, 20, 10, 4096)
	if err == nil || !strings.Contains(err.Error(), "adapter emitted a symlink") {
		t.Fatalf("err = %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Errorf("the sleeping adapter was not stopped: %v", time.Since(start))
	}
}

func TestSpawnFailureIsATypedError(t *testing.T) {
	e, root := runnerEnv(t)
	if _, err := e.runAdapter([]string{filepath.Join(root, "missing")}, root, root, baseEnv, 5, 10, 4096); err == nil {
		t.Fatal("starting a missing program must fail")
	}
}

func TestSignalReturnCodeIsNegative(t *testing.T) {
	e, root := runnerEnv(t)
	out, err := e.runAdapter(sh(`kill -9 $$`), root, root, baseEnv, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if out.status != "failed" || out.returncode != -9 {
		t.Fatalf("outcome = %+v, want failed with returncode -9", out)
	}
}

func TestAdapterRunsWithExactlyTheGivenEnvironmentAndDirectory(t *testing.T) {
	e, root := runnerEnv(t)
	_, err := e.runAdapter(sh(`pwd; env | sort`), root, root, []string{"PATH=/usr/bin:/bin", "ONLY=this"}, 5, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(root, "stdout.raw.txt"))
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if lines[0] != root {
		t.Errorf("cwd = %q, want %q", lines[0], root)
	}
	for _, l := range lines[1:] {
		if !strings.HasPrefix(l, "ONLY=") && !strings.HasPrefix(l, "PATH=") && !strings.HasPrefix(l, "PWD=") && !strings.HasPrefix(l, "_=") && !strings.HasPrefix(l, "OLDPWD=") && !strings.HasPrefix(l, "SHLVL=") {
			t.Errorf("unexpected variable %q: the environment must not be inherited", l)
		}
	}
}

func TestRunWithoutAHelperCannotLowerTheLimitAndSaysSo(t *testing.T) {
	e, root := runnerEnv(t)
	e.helper = func() (string, error) { return "", os.ErrNotExist }
	if _, err := e.runAdapter(sh("exit 0"), root, root, baseEnv, 5, 10, 4096); err == nil || !strings.Contains(err.Error(), "cannot locate the rsdd binary") {
		t.Fatalf("err = %v", err)
	}
}
