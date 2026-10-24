//go:build unix

package proc

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const testPath = "PATH=/usr/bin:/bin"

// shSpec runs script under /bin/sh in a fresh directory. The script first
// records its process group (it leads it: Setpgid) so cleanup can stop any
// survivor through the guard, never through a raw pid.
func shSpec(t *testing.T, script string) Spec {
	t.Helper()
	dir := t.TempDir()
	t.Cleanup(func() {
		if b, err := os.ReadFile(filepath.Join(dir, "pgid")); err == nil {
			if pgid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				_ = KillGroup(pgid, pgid)
			}
		}
	})
	return Spec{
		Argv: []string{"/bin/sh", "-c", "echo $$ > pgid; " + script}, Dir: dir, Env: []string{testPath},
		Timeout: 10 * time.Second, MaxBytes: 1 << 20, Grace: 5 * time.Second,
	}
}

func pgidOf(t *testing.T, s Spec) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(s.Dir, "pgid"))
	if err != nil {
		t.Fatalf("child group not recorded: %v", err)
	}
	pgid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	return pgid
}

// run calls Run with a test-side bound: a Run that never returns (a mutant
// that drops the KILL) fails the test instead of hanging it.
func run(t *testing.T, s Spec) (Result, time.Duration) {
	t.Helper()
	type out struct {
		r   Result
		err error
	}
	done := make(chan out, 1)
	start := time.Now()
	go func() { r, err := Run(s); done <- out{r, err} }()
	select {
	case o := <-done:
		if o.err != nil {
			t.Fatalf("Run: %v", o.err)
		}
		return o.r, time.Since(start)
	case <-time.After(30 * time.Second):
		t.Fatal("Run did not return within 30s")
	}
	return Result{}, 0
}

func wantErrors(t *testing.T, r Result, want ...string) {
	t.Helper()
	if got := r.Errors(); !slices.Equal(got, want) && !(len(got) == 0 && len(want) == 0) {
		t.Fatalf("Errors() = %q, want %q (result %+v)", got, want, r)
	}
}

func TestRunCapturesOutputAndExitCode(t *testing.T) {
	r, _ := run(t, shSpec(t, `printf out; printf err >&2; exit 3`))
	if string(r.Stdout) != "out" || string(r.Stderr) != "err" || r.ReturnCode != 3 || r.Reason != "" {
		t.Fatalf("got %+v", r)
	}
	wantErrors(t, r, "analyzer-exit:3")
}

func TestRunCleanExitHasNoErrors(t *testing.T) {
	r, _ := run(t, shSpec(t, `printf ok`))
	if r.ReturnCode != 0 || string(r.Stdout) != "ok" {
		t.Fatalf("got %+v", r)
	}
	wantErrors(t, r)
}

func TestRunReportsAKillingSignalAsANegativeCode(t *testing.T) {
	r, _ := run(t, shSpec(t, `kill -USR1 $$`))
	if r.ReturnCode != -10 {
		t.Fatalf("ReturnCode %d, want -10 (SIGUSR1)", r.ReturnCode)
	}
	wantErrors(t, r, "analyzer-exit:-10")
}

// TERM first, then a grace period: a child that cleans up on TERM gets to
// finish (a straight KILL, or KILL without the grace, would cut its sleep).
func TestRunTimeoutTermsTheGroupAndHonoursTheGrace(t *testing.T) {
	s := shSpec(t, `trap 'sleep 0.3; echo bye; exit 7' TERM; sleep 30 & wait`)
	s.Timeout = 200 * time.Millisecond
	r, _ := run(t, s)
	if r.Reason != ReasonTimeout || r.ReturnCode != 7 || string(r.Stdout) != "bye\n" {
		t.Fatalf("got %+v, want a timeout that ended the child through its TERM trap", r)
	}
	wantErrors(t, r, "timeout")
	waitGone(t, pgidOf(t, s))
}

// A group that ignores TERM is KILLed once the grace runs out.
func TestRunTimeoutKillsAfterTheGrace(t *testing.T) {
	s := shSpec(t, `trap '' TERM; sleep 30 & wait`)
	s.Timeout, s.Grace = 200*time.Millisecond, 300*time.Millisecond
	r, el := run(t, s)
	if r.Reason != ReasonTimeout || r.ReturnCode != -9 {
		t.Fatalf("got %+v, want a timeout ended by SIGKILL", r)
	}
	if el < 500*time.Millisecond {
		t.Fatalf("returned after %s: the KILL came before timeout + grace", el)
	}
	waitGone(t, pgidOf(t, s))
}

func TestRunTimeoutKillsTheGrandchildren(t *testing.T) {
	s := shSpec(t, `sleep 30 & sleep 30 & wait`)
	s.Timeout = 200 * time.Millisecond
	r, _ := run(t, s)
	if r.Reason != ReasonTimeout {
		t.Fatalf("got %+v, want a timeout", r)
	}
	waitGone(t, pgidOf(t, s))
}

// As run_bounded stops the group after a normal exit too, a background job
// left behind is stopped, and its pipe end does not hold Run open.
func TestRunStopsLeftoversAfterANormalExit(t *testing.T) {
	r, el := run(t, shSpec(t, `sleep 30 & printf done`))
	if r.Reason != "" || r.ReturnCode != 0 || string(r.Stdout) != "done" || el > 4*time.Second {
		t.Fatalf("got %+v after %s, want a prompt clean exit", r, el)
	}
}

func TestRunOutputCapStopsAnEndlessWriter(t *testing.T) {
	s := shSpec(t, `yes`)
	s.MaxBytes = 1000
	r, el := run(t, s)
	if r.Reason != ReasonOutputCap || len(r.Stdout) != 1000 || el > 5*time.Second {
		t.Fatalf("reason %q, %d stdout bytes after %s; want output-cap with exactly 1000", r.Reason, len(r.Stdout), el)
	}
	if !bytes.HasPrefix(r.Stdout, []byte("y\ny\n")) {
		t.Fatalf("stdout %q, want the FIRST bytes kept", r.Stdout[:8])
	}
	wantErrors(t, r, "output-cap")
}

// The cap is joint: stdout keeps its bytes first, stderr gets the rest.
func TestRunOutputCapTruncatesJointly(t *testing.T) {
	s := shSpec(t, `printf '%060d' 0; printf '%060d' 1 >&2`)
	s.MaxBytes = 100
	r, _ := run(t, s)
	if r.Reason != ReasonOutputCap || len(r.Stdout) != 60 || string(r.Stderr) != strings.Repeat("0", 40) {
		t.Fatalf("got reason %q stdout %d stderr %q", r.Reason, len(r.Stdout), r.Stderr)
	}
}

// Reaching the cap exactly is a breach (run_bounded compares with >=); one
// byte under is not.
func TestRunOutputCapBoundary(t *testing.T) {
	for _, c := range []struct {
		n      int
		reason string
	}{{99, ""}, {100, ReasonOutputCap}} {
		s := shSpec(t, `head -c `+strconv.Itoa(c.n)+` /dev/zero`)
		s.MaxBytes = 100
		r, _ := run(t, s)
		if r.Reason != c.reason || len(r.Stdout) != c.n {
			t.Errorf("%d bytes: reason %q len %d, want %q", c.n, r.Reason, len(r.Stdout), c.reason)
		}
	}
}

func TestRunResolvesTheProgramOnTheSpecPath(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "tool"), []byte("#!/bin/sh\nprintf tool\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := shSpec(t, "")
	s.Argv, s.Env = []string{"tool"}, []string{"PATH=" + bin}
	r, _ := run(t, s)
	if string(r.Stdout) != "tool" {
		t.Fatalf("got %+v, want the tool found on the spec's PATH", r)
	}
}

func TestRunSpawnFailureIsTyped(t *testing.T) {
	for _, argv0 := range []string{"no-such-program-2283", "/nonexistent/prog", "./missing"} {
		for _, limits := range [][]Limit{nil, {{"nofile", 64}}} {
			s := Spec{Argv: []string{argv0}, Dir: t.TempDir(), Env: []string{testPath}, Timeout: time.Second, MaxBytes: 10, Limits: limits, Helper: os.Args[0]}
			_, err := Run(s)
			var se *SpawnError
			if !errors.As(err, &se) || se.Path != argv0 {
				t.Errorf("Run(%q, limits %v) = %v, want a *SpawnError for it", argv0, limits, err)
			}
		}
	}
	_, err := Run(Spec{Argv: []string{"no-such-program-2283"}, Env: []string{testPath}, Timeout: time.Second, MaxBytes: 10})
	if !errors.Is(err, exec.ErrNotFound) {
		t.Errorf("a program missing from PATH = %v, want exec.ErrNotFound", err)
	}
}

// A pipe that cannot be made is a spawn failure too: with no descriptor
// left (soft NOFILE 3: only stdin, stdout and stderr fit) the program is
// never started, and the caller can tell that from the error's type.
func TestRunPipeFailureIsASpawnError(t *testing.T) {
	var own syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &own); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &syscall.Rlimit{Cur: 3, Max: own.Max}); err != nil {
		t.Fatal(err)
	}
	_, err := Run(Spec{Argv: []string{"/bin/true"}, Timeout: time.Second, MaxBytes: 10})
	if rerr := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &own); rerr != nil {
		t.Fatalf("restore NOFILE: %v", rerr)
	}
	var se *SpawnError
	if !errors.As(err, &se) || se.Path != "/bin/true" || !errors.Is(err, syscall.EMFILE) {
		t.Fatalf("Run with no descriptor left = %v, want a *SpawnError for /bin/true wrapping EMFILE", err)
	}
}

func TestRunRejectsAnInvalidSpec(t *testing.T) {
	ok := Spec{Argv: []string{"/bin/true"}, Timeout: time.Second, MaxBytes: 1}
	for name, mut := range map[string]func(*Spec){
		"no argv":          func(s *Spec) { s.Argv = nil },
		"zero timeout":     func(s *Spec) { s.Timeout = 0 },
		"zero cap":         func(s *Spec) { s.MaxBytes = 0 },
		"negative grace":   func(s *Spec) { s.Grace = -1 },
		"limits no helper": func(s *Spec) { s.Limits = []Limit{{"nofile", 64}} },
		"bad limit":        func(s *Spec) { s.Limits, s.Helper = []Limit{{"bogus", 1}}, os.Args[0] },
	} {
		s := ok
		mut(&s)
		if _, err := Run(s); !errors.Is(err, ErrInvalidSpec) {
			t.Errorf("%s: Run = %v, want ErrInvalidSpec", name, err)
		}
	}
}

func TestRunAppliesLimitsThroughTheHelper(t *testing.T) {
	s := shSpec(t, `ulimit -n`)
	s.Limits, s.Helper = []Limit{{"nofile", 64}}, os.Args[0]
	r, _ := run(t, s)
	if string(r.Stdout) != "64\n" || r.ReturnCode != 0 {
		t.Fatalf("got %+v, want the child to see nofile 64", r)
	}
}

func TestRunStampsTheInjectedClock(t *testing.T) {
	t0 := time.Date(2026, 10, 24, 0, 0, 0, 0, time.UTC)
	calls := 0
	s := shSpec(t, `true`)
	s.Now = func() time.Time { calls++; return t0.Add(time.Duration(calls) * time.Second) }
	r, _ := run(t, s)
	if !r.Started.Equal(t0.Add(time.Second)) || !r.Ended.Equal(t0.Add(2*time.Second)) || r.Duration != time.Second {
		t.Fatalf("Started %v Ended %v Duration %v, want the clock's first and second reading 1s apart", r.Started, r.Ended, r.Duration)
	}
}

// Reaching the cap exactly stops a writer that then idles: the stop fires
// on the cap, not on the timeout.
func TestRunOutputCapStopsAtExactlyTheCap(t *testing.T) {
	s := shSpec(t, `head -c 100 /dev/zero; sleep 30`)
	s.MaxBytes = 100
	r, el := run(t, s)
	if r.Reason != ReasonOutputCap || el > 5*time.Second {
		t.Fatalf("reason %q after %s, want output-cap well before the 10s timeout", r.Reason, el)
	}
}

// A process that leaves the group (setsid) is out of the guard's reach and
// may hold the pipe forever; Run still returns once the grace runs out.
func TestRunDoesNotWaitForAnEscapedPipeHolder(t *testing.T) {
	needSetsid(t)
	s := shSpec(t, `setsid sh -c 'echo $$ > esc; exec sleep 30' & sleep 0.2; printf done`)
	s.Grace = 300 * time.Millisecond
	t.Cleanup(func() {
		if b, err := os.ReadFile(filepath.Join(s.Dir, "esc")); err == nil {
			if pgid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				_ = KillGroup(pgid, pgid)
			}
		}
	})
	r, el := run(t, s)
	if string(r.Stdout) != "done" || r.ReturnCode != 0 || el > 4*time.Second {
		t.Fatalf("got %+v after %s, want a prompt return despite the escaped holder", r, el)
	}
	if _, err := os.Stat(filepath.Join(s.Dir, "esc")); err != nil {
		t.Fatalf("the escaped holder never started (%v): the case proves nothing", err)
	}
}

func needSetsid(t *testing.T) {
	t.Helper()
	if _, err := os.Stat("/usr/bin/setsid"); err != nil {
		t.Skip("/usr/bin/setsid not available (the spec PATH is /usr/bin:/bin)")
	}
}
