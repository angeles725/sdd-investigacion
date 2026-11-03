//go:build unix

package verify

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Bounds of the skill-drift hook that the shell suite pinned with real processes and a hanging git: the bound
// on install --verify and on its stray children, the shared kit-staleness budget, and the typed states of the
// two git facts the age criterion needs (the FETCH_HEAD path and its age). None of these tests reads the frozen
// bash oracle, so they run in the teeth build too.

const timedOutText = "verify: install --verify timed out"

// pidAlive tells whether pid is a live process. A zombie (killed, not yet reaped by its new parent) is dead.
func pidAlive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid)); err == nil {
		s := string(b)
		if i := strings.LastIndexByte(s, ')'); i >= 0 && i+2 < len(s) && s[i+2] == 'Z' {
			return false
		}
	}
	return true
}

// readPIDs reads the pids a stub appended to file, one per line.
func readPIDs(t *testing.T, file string) []int {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("the stub recorded no pid: %v", err)
	}
	var pids []int
	for _, f := range strings.Fields(string(b)) {
		n, err := strconv.Atoi(f)
		if err != nil {
			t.Fatalf("bad pid %q: %v", f, err)
		}
		pids = append(pids, n)
	}
	return pids
}

// waitDead polls until none of pids is alive, up to limit; it returns the ones still alive.
func waitDead(pids []int, limit time.Duration) []int {
	deadline := time.Now().Add(limit)
	for {
		var alive []int
		for _, p := range pids {
			if pidAlive(p) {
				alive = append(alive, p)
			}
		}
		if len(alive) == 0 || time.Now().After(deadline) {
			return alive
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// killAll is the cleanup of a test that may leak the stub's own children: by recorded pid, never by name.
func killAll(t *testing.T, pids []int) {
	for _, p := range pids {
		_ = syscall.Kill(p, syscall.SIGKILL)
	}
}

// H4e: a grandchild that keeps the stdout pipe open must not make the hook wait for it, and the bound is
// reported as a timeout. The grandchild is also gone afterwards (the whole group is stopped).
func TestSkillDriftHookStalledGrandchildHoldingStdoutIsBounded(t *testing.T) {
	w := hookWorld(t)
	pidFile := filepath.Join(w.root, "grandchild.pid")
	w.installStub("sleep 60 &\necho $! >" + pidFile + "\nexec sleep 60")
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "1"
	start := time.Now()
	out, errs, rc := w.runGoHook()
	elapsed := time.Since(start)
	if pids := readPIDs(t, pidFile); len(pids) == 1 {
		defer killAll(t, pids)
		if alive := waitDead(pids, 5*time.Second); len(alive) != 0 {
			t.Errorf("the grandchild %v outlived the hook", alive)
		}
	}
	if rc != 0 || errs != "" || !strings.Contains(out, timedOutText) {
		t.Errorf("hook rc=%d stderr=%q stdout=%q: want exit 0 and %q", rc, errs, out, timedOutText)
	}
	// The property is "the hook does not wait for the 60 s grandchild"; the ceiling only has to sit far below
	// it and above the 1 s bound plus the stop grace and a loaded host's slack.
	if elapsed > 20*time.Second {
		t.Errorf("the hook took %v with a 1 s bound and a 60 s grandchild holding stdout", elapsed)
	}
}

// H4g, H4j: an install --verify that finishes fast leaves no background job behind. The shell suite looked for
// the hook's own processes by command line; the Go hook runs in the caller's process and has no watchdog, so
// what can leak is what the stub started. The check is by the pids the test's stubs recorded.
func TestSkillDriftHookFastFinishesLeaveNoDescendants(t *testing.T) {
	w := hookWorld(t)
	pidFile := filepath.Join(w.root, "bg.pids")
	w.installStub("sleep 300 >/dev/null 2>&1 &\necho $! >>" + pidFile + "\nexit 0")
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "30"
	for i := 0; i < 10; i++ {
		w.wantHook("")
	}
	pids := readPIDs(t, pidFile)
	defer killAll(t, pids)
	if len(pids) != 10 {
		t.Fatalf("the stubs recorded %d pids, want 10", len(pids))
	}
	if alive := waitDead(pids, 5*time.Second); len(alive) != 0 {
		t.Errorf("background jobs %v survive 10 fast finishes", alive)
	}
}

// H4o: a verify that finishes inside the bound is never reported as timed out. A timeout seen only after the
// bound really elapsed is legitimate on a loaded host and is not counted.
func TestSkillDriftHookFastVerifyIsNeverReportedTimedOut(t *testing.T) {
	w := hookWorld(t)
	w.installStub("sleep 0.2")
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "1"
	early := 0
	for i := 0; i < 10; i++ {
		start := time.Now()
		out, _, _ := w.runGoHook()
		if strings.Contains(out, "timed out") && time.Since(start) < time.Second {
			early++
		}
	}
	if early != 0 {
		t.Errorf("%d/10 runs reported a timeout before the 1 s bound elapsed", early)
	}
}

// fakeGit puts a git in front of the world's PATH that runs body (a shell snippet that may exec the real git
// through $REAL) and returns the real git's path.
func (w *sdWorld) fakeGit(body string) {
	w.t.Helper()
	real, err := exec.LookPath("git")
	if err != nil {
		w.t.Fatal(err)
	}
	dir := filepath.Join(w.root, "fakegit")
	w.put(filepath.Join(dir, "git"), "#!/bin/sh\nREAL="+real+"\n"+body+"\n", 0o755)
	w.env["PATH"] = dir + ":" + w.env["PATH"]
}

const behindLine = "verify kit status=behind by 3"

// K16: a git that never answers is cut off by ONE shared 3 s budget; the state is unknown, so install
// --verify's own behind line is kept; verbose says the check was abandoned.
func TestSkillDriftHookHangingGitIsCutOffByTheSharedBudget(t *testing.T) {
	w := hookWorld(t)
	w.gitKit(25)
	w.installStub("echo '" + behindLine + "'")
	w.fakeGit("exec sleep 60")
	start := time.Now()
	w.wantHook(hdrInstall + "\n" + behindLine)
	if d := time.Since(start); d > 15*time.Second {
		t.Errorf("a hanging git held the hook for %v (budget 3 s)", d)
	}
	w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w.wantHook(hdrInstall + "\n" + behindLine + "\nverify kit-stale status=degraded reason=git did not answer within 3s (check abandoned)")
}

// The budget is shared, not per call: a git that answers every call in 2 s (inside 3 s each) still exhausts it
// by the second call, and the check is abandoned instead of finishing after ~10 s.
func TestSkillDriftHookSlowGitSpendsOneBudgetNotOnePerCall(t *testing.T) {
	w := hookWorld(t)
	w.gitKit(25)
	w.installStub("echo '" + behindLine + "'")
	w.fakeGit("sleep 2\nexec \"$REAL\" \"$@\"")
	start := time.Now()
	w.wantHook(hdrInstall + "\n" + behindLine)
	if d := time.Since(start); d > 9*time.Second {
		t.Errorf("slow git took %v: the 3 s budget is not shared", d)
	}
}

// K19, K19b: a failing `rev-parse --git-path FETCH_HEAD` must not become "<kit>/" (a path that always looks
// fresh): the state is unknown and install --verify's behind line is kept; verbose types the failure.
func TestSkillDriftHookFailedGitPathLookupIsUnknownNotFresh(t *testing.T) {
	w := hookWorld(t)
	w.gitKit(3)
	w.installStub("echo '" + behindLine + "'")
	w.fakeGit("case \"$*\" in *--git-path*) exit 1 ;; esac\nexec \"$REAL\" \"$@\"")
	w.wantHook(hdrInstall + "\n" + behindLine)
	w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w.wantHook(hdrInstall + "\n" + behindLine + "\nverify kit-stale status=degraded reason=could not locate FETCH_HEAD (git rev-parse --git-path failed)")
}

// K18, K18b, K18c: with no usable fetch age the commit count still governs and the age shows as `?`. (The shell
// suite got there with a failing `stat` binary; Go stats the file itself, so the state is reached with no
// FETCH_HEAD. The "cannot read the age" branch needs a FETCH_HEAD that exists as a file yet fails os.Stat a
// moment later, which a test cannot arrange.)
func TestSkillDriftHookUnknownFetchAgeLetsTheCountGovern(t *testing.T) {
	w := hookWorld(t)
	kit := w.gitKit(25)
	if err := os.Remove(filepath.Join(kit, ".git", "FETCH_HEAD")); err != nil {
		t.Fatal(err)
	}
	w.wantHook(hdrInstall + "\n" + staleLine("~/kitrepo", "pull --ff-only", "25", "20", "?", "7"))

	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "30" // within the threshold: silent at SessionStart
	w.wantHook("")
	w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w.wantHook(hdrInstall + "\nverify kit-stale status=degraded reason=no FETCH_HEAD (never fetched): age criterion skipped, judged by commit count only (behind=25 of max 30)")
}

// K13b: a never-fetched clone whose .git/config is 10 days old stays silent: the config's mtime is not an age
// source (any git config write resets it).
func TestSkillDriftHookConfigMtimeIsNotAnAgeSource(t *testing.T) {
	w := hookWorld(t)
	kit := w.gitKit(0)
	if err := os.Remove(filepath.Join(kit, ".git", "FETCH_HEAD")); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-10 * 24 * time.Hour)
	for _, f := range []string{"config", "HEAD", "index"} {
		if err := os.Chtimes(filepath.Join(kit, ".git", f), old, old); err != nil {
			t.Fatal(err)
		}
	}
	w.wantHook("")
}
