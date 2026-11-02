//go:build linux

package carve

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestStatOfComposesNanosecondTimestamps(t *testing.T) {
	var st syscall.Stat_t
	st.Dev, st.Ino, st.Mode, st.Size = 1, 2, 3, 4
	st.Mtim.Sec, st.Mtim.Nsec = 5, 6
	st.Ctim.Sec, st.Ctim.Nsec = 7, 8
	want := statTuple{1, 2, 3, 4, 5*1e9 + 6, 7*1e9 + 8}
	if got := statOf(&st); got != want {
		t.Errorf("statOf = %+v, want %+v", got, want)
	}
}

func TestProcessTreeReadsTheProcessTable(t *testing.T) {
	dir := t.TempDir()
	for name, stat := range map[string]string{
		"100": ") S 1",           // no pid or name before the paren, exactly state and parent after it
		"101": "101 (x y) S 100", // a name with a space; child of 100
		"102": "102 (x) S 101 1", // grandchild
		"103": "103 no paren S 100",
		"104": "104 (x) S",    // no parent field
		"105": "105 (x) S 77", // unrelated
	} {
		if err := os.Mkdir(filepath.Join(dir, name), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name, "stat"), []byte(stat), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "self"), nil, 0o644); err != nil { // not a pid
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "106"), 0o755); err != nil { // a pid whose stat cannot be read
		t.Fatal(err)
	}
	old := procDir
	procDir = dir
	t.Cleanup(func() { procDir = old })
	if n := processTree(100); n != 3 {
		t.Errorf("processTree(100) = %d, want 3 (100, 101, 102)", n)
	}
	if n := processTree(103); n != 0 {
		t.Errorf("processTree of an unparsable entry = %d, want 0", n)
	}
	procDir = filepath.Join(dir, "absent")
	if n := processTree(100); n != 0 {
		t.Errorf("processTree with no process table = %d, want 0", n)
	}
}

func TestLaunchedWorkerTimesOutExactlyAtTheBound(t *testing.T) {
	base := time.Unix(1000, 0)
	calls := 0
	clock := func() time.Time { // the first reading starts the run; every later one is exactly the bound later
		calls++
		if calls == 1 {
			return base
		}
		return base.Add(time.Second)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	err = launchWorker(launchSpec{argv: []string{"/bin/sh", "-c", "sleep 4"}, dir: t.TempDir(), self: self, timeout: time.Second, maxProcs: 4, memory: roomyMemory, now: clock})
	if err == nil || err.Error() != "timeout" {
		t.Errorf("err = %v, want timeout", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("a worker held to its bound ran %v", time.Since(start))
	}
}

func TestLaunchedWorkerProcessCapIsInclusive(t *testing.T) {
	t.Parallel()                           // waits on real timers; overlapping them keeps the teeth run inside the CI job cap
	const two = "sleep 1 & sleep 1 & wait" // exactly two descendants of the shell
	if err := launch(t, two, 10*time.Second, 2, roomyMemory); err != nil {
		t.Errorf("two descendants under a cap of two: err = %v, want nil", err)
	}
	if err := launch(t, two, 10*time.Second, 1, roomyMemory); err == nil || err.Error() != "process cap" {
		t.Errorf("two descendants under a cap of one: err = %v, want process cap", err)
	}
}
