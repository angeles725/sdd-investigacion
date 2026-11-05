package flakehunt

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// exitNotRunnable is the shell's code for a command that could not be started.
const exitNotRunnable = 127

// suiteEnv is the environment of one suite: the caller's without the CI tokens (a suite under test must neither see
// nor leak them; only gh gets GH_TOKEN), plus its own TMPDIR and the FLAKE_HUNT_* variables.
func suiteEnv(base []string, tmp string, run int, suite, out string) []string {
	env := make([]string, 0, len(base)+4)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "GH_TOKEN", "GITHUB_TOKEN", "TMPDIR", "FLAKE_HUNT_RUN", "FLAKE_HUNT_SUITE", "FLAKE_HUNT_OUT":
		default:
			env = append(env, kv)
		}
	}
	return append(env, "TMPDIR="+tmp, "FLAKE_HUNT_RUN="+strconv.Itoa(run), "FLAKE_HUNT_SUITE="+suite, "FLAKE_HUNT_OUT="+out)
}

// runner is the command line of a suite below `timeout S`: *.test.mjs under node, everything else under bash
// (--prove-teeth only for the shell ones, as run-all.sh does).
func (h *hunt) runner(suite string) []string {
	p := suitePath(h.repo, suite)
	if strings.HasSuffix(suite, ".test.mjs") {
		return []string{"node", p}
	}
	if h.c.o.prove {
		return []string{"bash", p, "--prove-teeth"}
	}
	return []string{"bash", p}
}

// runSuite runs suite number idx of run `run` into its own log with its own TMPDIR, bounded by --suite-timeout, and
// returns the shell exit code (124 timed out, 127 not startable). interrupted is the exit code of an INT/TERM that
// arrived meanwhile (0: none): the suite's process group is stopped and its TMPDIR removed.
func (h *hunt) runSuite(run, idx int, suite string) (rc, interrupted int) {
	log := h.logPath(run, idx)
	tmp := fmt.Sprintf("%s/tmp/%d-%d", h.out, run, idx)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return exitNotRunnable, 0
	}
	defer os.RemoveAll(tmp)
	lf, err := os.Create(log)
	if err != nil {
		return exitNotRunnable, 0
	}
	defer lf.Close()
	cmd := exec.Command(h.tools.timeout)
	cmd.Args = append([]string{"timeout", strconv.Itoa(h.c.suiteTimeout)}, h.runner(suite)...)
	cmd.Dir, cmd.Env = h.repo, suiteEnv(h.env, tmp, run, suite, h.out)
	cmd.Stdout, cmd.Stderr = lf, lf
	kitmaint.ProcAttr(cmd)
	if err := cmd.Start(); err != nil {
		return exitNotRunnable, 0
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	if h.intr.await(done) {
		kitmaint.SignalGroup(cmd, false)
		select {
		case <-done:
		case <-time.After(stopGrace):
			kitmaint.SignalGroup(cmd, true)
			<-done
		}
		return exitNotRunnable, h.intr.code
	}
	return kitmaint.ExitCode(cmd.ProcessState), 0
}

func (h *hunt) logPath(run, idx int) string { return fmt.Sprintf("%s/logs/%d-%d.log", h.out, run, idx) }
