package prpipeline

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// A signal during the gate step must stop the gate's whole process group and release gate.lock: the legacy kit-gate.sh
// ran in the caller's group, so Ctrl-C killed the tree and the next pipeline could take the lock.
func TestSignalStopsTheGateGroupAndReleasesTheLock(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	pidf := w.Dir + "/gate.pid"
	sigs := make(chan os.Signal, 2)
	go func() {
		for i := 0; i < 400; i++ {
			if _, err := os.Stat(pidf); err == nil {
				break
			}
			time.Sleep(25 * time.Millisecond)
		}
		sigs <- syscall.SIGTERM
	}()
	start, drive := fakes()
	s, o, _ := w.Stdio(w.Wt, prepare(t, w), "GATEPID="+pidf)
	cmd := `sleep 25 & echo $! > "$GATEPID.t"; mv "$GATEPID.t" "$GATEPID"; wait`
	rc := run([]string{"--state-dir", w.Dir + "/st", "--gate-cmd", cmd, w.Wt, "7", "b"}, s,
		deps{start: start, drive: drive, sleep: func(time.Duration) {},
			notify: func() (<-chan os.Signal, func()) { return sigs, func() {} }})
	b, err := os.ReadFile(pidf)
	if err != nil {
		t.Fatalf("the gate never started: rc=%d out=%s", rc, o.String())
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	defer func() { _ = syscall.Kill(pid, syscall.SIGKILL) }()
	if rc != 16 || !strings.HasSuffix(o.String(), "kit-pr-pipeline: interrupted: #7: the gate was stopped by a signal; CI and merge were not attempted\n") {
		t.Errorf("rc=%d out=%q", rc, o.String())
	}
	dead := false
	for i := 0; i < 150 && !dead; i++ {
		dead = syscall.Kill(pid, 0) == syscall.ESRCH
		time.Sleep(20 * time.Millisecond)
	}
	if !dead {
		t.Errorf("the gate's child %d survived the signal", pid)
	}
	lock, err := os.OpenFile(w.Dir+"/st/gate.lock", os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if !kitmaint.Flock(lock, 0, time.Sleep) {
		t.Error("gate.lock is still held after the signal")
	}
	if strings.Contains(w.Calls(), "gh pr checks") {
		t.Errorf("CI must not be polled after an interrupted gate: %q", w.Calls())
	}
}

// The merge gate is checked before polling (kit-wait-merge.sh: `[ -f "$mg" ]` -> exit 3), not found at merge time as
// a refusal after the whole CI wait.
func TestMissingMergeGateIsDegradedBeforePolling(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, "KIT_MERGE_GATE=/nonexistent/merge-gate.sh")
	want := "kit-wait-merge: degraded: merge-gate.sh not found: /nonexistent/merge-gate.sh\n" +
		"kit-pr-pipeline: degraded: kit-wait-merge.sh reported a missing dependency\n"
	if r.err != "DEGRADED: merge-gate.sh not found: /nonexistent/merge-gate.sh\n" {
		t.Errorf("stderr must name the reason: %q", r.err)
	}
	if r.rc != 3 || !strings.HasSuffix(r.out, want) || strings.Contains(w.Calls(), "gh pr checks") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}

// With no script the rsdd binary's own `gate merge` runs; a binary that cannot be told is the same degraded state.
func TestUnknownBinaryIsDegradedBeforePolling(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, "KIT_MERGE_GATE=")
	want := "kit-wait-merge: degraded: merge-gate.sh not found: the rsdd binary (the default merge gate) cannot be located\n" +
		"kit-pr-pipeline: degraded: kit-wait-merge.sh reported a missing dependency\n"
	if r.err != "DEGRADED: merge-gate.sh not found: the rsdd binary (the default merge gate) cannot be located\n" {
		t.Errorf("stderr must name the reason: %q", r.err)
	}
	if r.rc != 3 || !strings.HasSuffix(r.out, want) || strings.Contains(w.Calls(), "gh pr checks") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}

// Legacy ran from the worktree (`cd "$wt"`), so a relative KIT_MERGE_GATE names a file under it, not under the
// caller's directory.
func TestRelativeMergeGateResolvesFromTheWorktree(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	prepare(t, w)
	if err := os.MkdirAll(w.Wt+"/sub", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(w.Fix+"/shim.sh", w.Wt+"/sub/merge-gate.sh"); err != nil {
		t.Fatal(err)
	}
	start, drive := fakes()
	s, o, _ := w.Stdio(w.Dir, "KIT_MERGE_GATE=sub/merge-gate.sh") // the caller is NOT in the worktree
	rc := run([]string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, s, deps{start: start, drive: drive, sleep: func(time.Duration) {}})
	if rc != 0 || !strings.Contains(w.Calls(), "merge-gate.sh --cwd "+w.Wt) {
		t.Errorf("rc=%d out=%q calls=%q", rc, o.String(), w.Calls())
	}
}

// A non-numeric knob is a usage error before anything runs, not a silent 0 that skips the CI wait.
func TestNonNumericKnobIsAUsageError(t *testing.T) {
	for _, knob := range []string{"KIT_POLL_MAX", "KIT_MERGE_TRIES", "KIT_POLL_SLEEP", "KIT_MERGE_SLEEP", "KIT_RETRY_SLEEP"} {
		w := kitworld.New(t)
		happy(w)
		r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, knob+"=abc")
		want := "kit-pr-pipeline: usage: " + knob + " must be a whole number: abc\n"
		if r.rc != 2 || r.out != want || strings.TrimSpace(w.Calls()) != "" {
			t.Errorf("%s: %+v calls=%q", knob, r, w.Calls())
		}
	}
}

func TestHelpDoesNotNameAnyPython(t *testing.T) {
	if strings.Contains(help, "python") {
		t.Errorf("the pipeline no longer needs python3: %s", help)
	}
}

// Drive lines are cut at 300 characters, never inside a rune (the legacy `cut -c` counted bytes; a declared divergence).
func TestDriveLinesAreCutAtCharacters(t *testing.T) {
	wide := strings.Repeat("é", 400)
	got := tailLines(wide + "\nshort\n")
	if len(got) != 2 || utf8.RuneCountInString(got[0]) != 300 || !utf8.ValidString(got[0]) || got[1] != "short" {
		t.Errorf("%q", got)
	}
	if got := tailLines(strings.Repeat("é", 200) + "\n"); utf8.RuneCountInString(got[0]) != 200 {
		t.Errorf("a line under 300 characters is kept whole: %q", got)
	}
}
