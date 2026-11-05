package flakehunt

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// workerScan is a fake-suite prelude: count the busy-loop workers of this run's output directory by scanning /proc
// (no ps, no CPU), polling up to 3 s for N of them because the tool starts workers and suite back to back.
const workerScan = `c(){ { for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' <"$f"; echo; done; } 2>/dev/null | grep -c "^timeout [0-9]* bash -c .*kit-flake-hunt-load:$FLAKE_HUNT_OUT"; }; w(){ for _ in $(seq 1 30); do [ "$(c)" -ge "$1" ] && break; sleep 0.1; done; }; `

func gone(t *testing.T, tag string) {
	t.Helper()
	for i := 0; i < 30; i++ {
		if len(leftovers(tag)) == 0 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("processes still carry %s: %v", tag, leftovers(tag))
}

func TestLoadWorkersAreSpawnedDuringTheRunAndReapedAfterIt(t *testing.T) {
	w := newWorld(t)
	w.suite("mid.test.sh", workerScan+`w 2; c >`+w.rec+`/during; echo '== 1 passed · 0 failed =='`)
	out := w.root + "/o1"
	r := w.goRun("--repo", w.repo, "--out", out, "--runs", "1", "--load", "2", "--load-timeout", "20", "--suite", "s/mid.test.sh")
	if r.rc != 0 {
		t.Fatalf("rc %d err=%q out=%q", r.rc, r.err, r.out)
	}
	b, _ := os.ReadFile(w.rec + "/during")
	if strings.TrimSpace(string(b)) != "2" {
		t.Errorf("want 2 busy workers during the run, saw %q", b)
	}
	gone(t, "kit-flake-hunt-load:"+out)
}

func TestLoadZeroSpawnsNoWorker(t *testing.T) {
	w := newWorld(t)
	w.suite("mid.test.sh", workerScan+`c >`+w.rec+`/during; echo '== 1 passed · 0 failed =='`)
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "1", "--load", "0", "--suite", "s/mid.test.sh")
	b, _ := os.ReadFile(w.rec + "/during")
	if r.rc != 0 || strings.TrimSpace(string(b)) != "0" {
		t.Errorf("rc %d, workers %q (want 0)", r.rc, b)
	}
}

func TestLoadWorkersExpireAtTheLoadTimeout(t *testing.T) {
	w := newWorld(t)
	w.suite("late.test.sh", workerScan+`w 1; c >`+w.rec+`/early; sleep 2.6; c >`+w.rec+`/late; echo '== 1 passed · 0 failed =='`)
	w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "1", "--load", "1", "--load-timeout", "1", "--suite", "s/late.test.sh")
	early, _ := os.ReadFile(w.rec + "/early")
	late, _ := os.ReadFile(w.rec + "/late")
	if strings.TrimSpace(string(early)) != "1" || strings.TrimSpace(string(late)) != "0" {
		t.Errorf("want 1 worker early and 0 late, saw %q and %q", early, late)
	}
}

func TestDefaultLoadIsHalfTheCPUs(t *testing.T) {
	w := newWorld(t)
	w.suite("ok.test.sh", bodyStable)
	nproc, err := exec.Command("nproc").Output()
	if err != nil {
		t.Skip("no nproc")
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(nproc)))
	want := max(n/2, 1)
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "1", "--suite", "s/ok.test.sh")
	if !strings.Contains(r.out, "load="+strconv.Itoa(want)+" ") {
		t.Errorf("want load=%d (nproc %d), got %q", want, n, r.out)
	}
	gone(t, "kit-flake-hunt-load:"+w.root+"/o1")
}

// interrupted runs the hunt with a hanging suite and two workers, delivers sig through the injected source once
// both are up, and reports the exit code and how long the command took to end.
func interrupted(t *testing.T, sig os.Signal) (w *world, rc int, took time.Duration) {
	t.Helper()
	w = newWorld(t)
	w.suite("hang.test.sh", "exec sleep 9.137")
	ch := make(chan os.Signal, 1)
	done := make(chan ran, 1)
	go func() {
		done <- w.goRunWith(deps{notify: func() (<-chan os.Signal, func()) { return ch, func() {} }},
			"--repo", w.repo, "--out", w.root+"/o1", "--runs", "1", "--load", "2", "--load-timeout", "20", "--suite-timeout", "8", "--suite", "s/hang.test.sh")
	}()
	tag := "kit-flake-hunt-load:" + w.root + "/o1"
	for i := 0; i < 100 && (len(leftovers(tag)) < 2 || len(leftovers("sleep\x009.137")) < 1); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	if len(leftovers(tag)) < 2 {
		t.Fatalf("the workers never started")
	}
	t0 := time.Now()
	ch <- sig
	select {
	case r := <-done:
		rc = r.rc
	case <-time.After(10 * time.Second):
		t.Fatal("the interrupted command did not end")
	}
	took = time.Since(t0)
	gone(t, tag)
	gone(t, "sleep\x009.137")
	return w, rc, took
}

func TestTermStopsWorkersAndSuiteAndExits143(t *testing.T) {
	w, rc, took := interrupted(t, syscall.SIGTERM)
	if rc != 143 || took > 3*time.Second {
		t.Errorf("rc %d after %v, want 143 within 3s", rc, took)
	}
	if ents, _ := os.ReadDir(w.root + "/o1/tmp"); len(ents) != 0 {
		t.Errorf("the interrupted suite's TMPDIR was left behind: %v", ents)
	}
}

func TestIntStopsWorkersAndSuiteAndExits130(t *testing.T) {
	if _, rc, _ := interrupted(t, syscall.SIGINT); rc != 130 {
		t.Errorf("rc %d, want 130", rc)
	}
}
