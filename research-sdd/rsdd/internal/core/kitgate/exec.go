package kitgate

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// summaryLines are the log lines kit-gate echoes (`grep -E ... | tail -15`).
var summaryLines = regexp.MustCompile(`AGGREGATE|passed|failed|Suites|FAIL  |leftovers|hermeticity`)

const summaryMax = 15

// writeSummary echoes the last summaryMax matching lines of the log.
func writeSummary(out io.Writer, log string) {
	data, err := os.ReadFile(log)
	if err != nil {
		return
	}
	var hit []string
	for _, ln := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if summaryLines.MatchString(ln) {
			hit = append(hit, ln)
		}
	}
	hit = hit[max(0, len(hit)-summaryMax):]
	for _, ln := range hit {
		fmt.Fprintln(out, ln)
	}
}

// killGrace is how long a TERMed gate gets before its process group is KILLed.
const killGrace = 10 * time.Second

// execGate is `bash -c CMD >> log 2>&1` inside the worktree. The lock file travels to the child as fd 3, so whatever
// the gate leaves running keeps the lock exactly as the bash fd 9 did. rc is the shell's code; fail is
// a typed exit code (usage, degraded) when the run could not start.
func execGate(o *Opts, cmd, wtPhys, log string, lock *os.File) (rc int, interrupted bool, fail int) {
	lf, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		o.say("usage: cannot write %s", log)
		return 0, false, ExitUsage
	}
	defer lf.Close()
	bash, err := probe.New(o.R.Env, o.R.Cwd).LookPath("bash")
	if err != nil {
		if !o.SilentNoBash {
			o.say("degraded: missing runtime dependency: bash")
		}
		return 0, false, ExitDegraded
	}
	c := exec.Command(bash, "-c", cmd)
	c.Dir, c.Env = wtPhys, append(append([]string(nil), o.R.Env...), "PWD="+wtPhys)
	c.Stdout, c.Stderr = lf, lf
	c.ExtraFiles = []*os.File{lock}
	kitmaint.ProcAttr(c)
	if c.Start() != nil {
		return 127, false, 0
	}
	done := make(chan struct{})
	go func() { _ = c.Wait(); close(done) }()
	var kill <-chan time.Time
	sig := o.Sig
	for {
		select {
		case <-done:
			return kitmaint.ExitCode(c.ProcessState), interrupted, 0
		case <-sig:
			interrupted = true
			sig = nil // a nil channel never fires; the first signal is the one that counts
			kitmaint.SignalGroup(c, false)
			kill = time.After(killGrace)
		case <-kill:
			kitmaint.SignalGroup(c, true)
			kill = nil
		}
	}
}
