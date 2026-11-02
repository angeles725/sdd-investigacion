package gate

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// kitGate is toolbelt/maint/kit-gate.sh <worktree> <label>, in-process: ONE serial gate under a flock on
// <state>/gate.lock, its output in <state>/gate-<label>.log, the summary lines echoed. It returns the typed exit
// code of the bash tool (0 passed, 2 usage, 16 gate-failed, 22 gate-lock-timeout) and the gate command's own rc.
func (g *train) kitGate(label string) (code, gateRC int) {
	say := func(format string, a ...any) { fmt.Fprintf(g.s.Out, "kit-gate: %s\n", fmt.Sprintf(format, a...)) }
	lockTimeout := g.s.Env("KIT_GATE_LOCK_TIMEOUT")
	if lockTimeout == "" {
		lockTimeout = "14400"
	}
	if !allDigits(lockTimeout) {
		say("usage: --lock-timeout must be a number of seconds")
		return 2, 0
	}
	cmd := g.gateCmd
	switch {
	case cmd != "":
	case g.serial:
		cmd = mtGateSerialCmd
	default:
		cmd = mtGateDefaultCmd
	}
	if !isDir(g.wt) {
		say("usage: worktree is not a directory: %s", g.wt)
		return 2, 0
	}
	wtPhys, err := g.resolveDir(g.wt)
	if err != nil {
		say("usage: cannot resolve the worktree")
		return 2, 0
	}
	statePhys, err := g.physPath(g.state)
	if err != nil {
		say("usage: cannot resolve --state-dir %s", g.state)
		return 2, 0
	}
	if strings.HasPrefix(statePhys+"/", wtPhys+"/") {
		say("usage: --state-dir %s is inside the worktree; state never lives in the repo", statePhys)
		return 2, 0
	}
	if err := os.MkdirAll(statePhys, 0o777); err != nil {
		say("usage: cannot create state dir %s", statePhys)
		return 2, 0
	}
	log := statePhys + "/gate-" + label + ".log"
	lock, err := os.OpenFile(statePhys+"/gate.lock", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		say("usage: cannot open the gate lock")
		return 2, 0
	}
	defer lock.Close()
	if !mtFlock(lock, atoi0(lockTimeout, 14400), g.d.sleep) {
		say("gate-lock-timeout: could not take %s/gate.lock within %ss", statePhys, lockTimeout)
		return 22, 0
	}

	short := strings.TrimRight(g.git(g.wt, "rev-parse", "--short", "HEAD").out, "\n")
	if err := os.WriteFile(log, []byte("head "+short+"\n"), 0o666); err != nil {
		say("usage: cannot write %s", log)
		return 2, 0
	}
	lf, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		say("usage: cannot write %s", log)
		return 2, 0
	}
	bash, err := probe.New(g.env, g.s.Cwd).LookPath("bash")
	if err != nil {
		lf.Close()
		return 3, 0
	}
	c := exec.Command(bash, "-c", cmd)
	c.Dir, c.Env = wtPhys, append(append([]string(nil), g.env...), "PWD="+wtPhys)
	c.Stdout, c.Stderr = lf, lf
	c.ExtraFiles = []*os.File{lock} // fd 3: whatever the gate leaves running keeps the lock, like the bash fd 9
	mtProcAttr(c)
	rc := 127
	if err := c.Start(); err == nil {
		done := make(chan struct{})
		go func() { _ = c.Wait(); close(done) }()
		var kill <-chan time.Time
		sig := g.sig
	wait:
		for {
			select {
			case <-done:
				break wait
			case <-sig:
				g.interrupted = true
				sig = nil // a nil channel never fires; the first signal is the one that counts
				mtSignalGroup(c, false)
				kill = time.After(10 * time.Second)
			case <-kill:
				mtSignalGroup(c, true)
				kill = nil
			}
		}
		rc = mtExitCode(c.ProcessState)
	}
	lf.Close()
	if g.interrupted {
		return 16, rc // the signal killed kit-gate.sh with its gate in the bash: no `gate rc=` line, no summary
	}
	if f, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0); err == nil {
		fmt.Fprintf(f, "gate rc=%d\n", rc)
		f.Close()
	}
	if data, err := os.ReadFile(log); err == nil {
		var hit []string
		for _, ln := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
			if mtGateLines.MatchString(ln) {
				hit = append(hit, ln)
			}
		}
		if len(hit) > 15 {
			hit = hit[len(hit)-15:]
		}
		for _, ln := range hit {
			fmt.Fprintln(g.s.Out, ln)
		}
	}
	say("gate rc=%d log=%s", rc, log)
	if rc != 0 {
		return 16, rc
	}
	return 0, 0
}
