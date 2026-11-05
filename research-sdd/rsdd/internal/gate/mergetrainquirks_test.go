package gate

import (
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// These tests pin what the merge train printed before its kit-wait-merge and kit-gate halves moved into core/kitwait
// and core/kitgate (shared with `rsdd maint`): the extraction must not change a byte of the train's output.

// flaky wraps the gh stub: the calls whose arguments match pattern fail (rc 1, "gh: boom" on stderr) the first
// times times, then go through to the stub.
func (c *mtCase) flaky(pattern string, times int) {
	c.t.Helper()
	if err := os.Rename(c.dir+"/bin/gh", c.dir+"/bin/gh-real"); err != nil {
		c.t.Fatal(err)
	}
	c.write("bin/gh", `#!/usr/bin/env bash
case "$*" in
  *"`+pattern+`"*)
    n=$(cat "$CASE/flaky-n" 2>/dev/null || echo 0)
    if [ "$n" -lt `+itoa(times)+` ]; then echo $((n + 1)) > "$CASE/flaky-n"; echo "gh: boom" >&2; exit 1; fi ;;
esac
exec "$CASE/bin/gh-real" "$@"
`)
	if err := os.Chmod(c.dir+"/bin/gh", 0o755); err != nil {
		c.t.Fatal(err)
	}
}

func itoa(n int) string { return string(rune('0' + n)) }

// A gh blip while confirming MERGED: the retry notes go to stderr under the kit-wait-merge prefix, the state read
// with its whole jq expression and the head/merge-commit read with the expression elided as `-q ...`.
func TestMergeTrainWaitRetryNotes(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	c.flaky("--json state -q", 1)
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 0 {
		t.Fatalf("rc=%d out=%s err=%s", r.rc, r.out, r.err)
	}
	if want := "gh: boom\nkit-wait-merge: retry 1/3 after rc=1: gh pr view 1 --json state -q .state\n"; !strings.Contains(r.err, want) {
		t.Errorf("state read note: err=%q, want it to contain %q", r.err, want)
	}

	c = newMtCase(t)
	c.mk(1)
	c.flaky("--json headRefOid,mergeCommit", 2)
	r = c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 0 {
		t.Fatalf("rc=%d out=%s err=%s", r.rc, r.out, r.err)
	}
	want := "gh: boom\nkit-wait-merge: retry 1/3 after rc=1: gh pr view 1 --json headRefOid,mergeCommit -q ...\n" +
		"gh: boom\nkit-wait-merge: retry 2/3 after rc=1: gh pr view 1 --json headRefOid,mergeCommit -q ...\n"
	if !strings.Contains(r.err, want) {
		t.Errorf("head read notes: err=%q, want it to contain %q", r.err, want)
	}
}

// The train never probed for bash: with none on PATH the gate cannot start, and the run ends at kit-gate's exit 3
// with nothing printed by kit-gate itself.
func TestMergeTrainGateWithoutBashIsSilent(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	b, err := os.ReadFile(c.dir + "/bin/gh")
	if err != nil {
		t.Fatal(err)
	}
	c.write("bin/gh", strings.Replace(string(b), "#!/usr/bin/env bash", "#!/bin/sh", 1))
	if err := os.Chmod(c.dir+"/bin/gh", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(c.dir + "/bin/bash"); err != nil {
		t.Fatal(err)
	}
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 29 || !strings.Contains(r.out, "train-error: kit-gate.sh exited 3") {
		t.Fatalf("rc=%d out=%s err=%s", r.rc, r.out, r.err)
	}
	if strings.Contains(r.out, "kit-gate: degraded") {
		t.Errorf("kit-gate printed a line the train never had: %s", r.out)
	}
}

// A lock timeout too long for an int made the train's flock wait zero seconds (one try, then gate-lock-timeout), not
// forever.
func TestMergeTrainHugeLockTimeoutTriesOnce(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	held, err := os.OpenFile(c.dir+"/state/gate.lock", os.O_WRONLY|os.O_CREATE, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if err := syscall.Flock(int(held.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	c.env = append(c.env, "KIT_GATE_LOCK_TIMEOUT=99999999999999999999")
	waits := 0
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, func(d *mtDeps) {
		d.sleep = func(time.Duration) {
			waits++
			if waits == 3 {
				_ = syscall.Flock(int(held.Fd()), syscall.LOCK_UN) // a hung wait ends here, and fails the test below
			}
		}
	})
	if waits != 0 {
		t.Errorf("the train waited %d times for a lock it should have tried once", waits)
	}
	if r.rc != 22 || !strings.Contains(r.out, "kit-gate: gate-lock-timeout: could not take") {
		t.Errorf("rc=%d out=%s", r.rc, r.out)
	}
}
