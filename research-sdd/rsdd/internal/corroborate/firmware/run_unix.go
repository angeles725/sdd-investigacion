//go:build linux || darwin

package firmware

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// runSpec is one bounded analyzer run. Its stdout and stderr are the files engine/stdout.txt and
// engine/stderr.txt under dir, rewritten by every run.
type runSpec struct {
	argv     []string
	dir      string
	env      []string // the whole environment of the run; nothing is inherited
	self     string   // this binary: it serves the rlimit re-exec helper
	timeout  time.Duration
	maxBytes int64
	maxProcs int
	now      func() time.Time
}

// Stop reasons, as the manifest and the report spell them.
const (
	reasonTimeout = "timeout"
	reasonOutput  = "diagnostic-cap"
	reasonProcs   = "process-cap"
)

const (
	pollEvery = 20 * time.Millisecond
	stopPoll  = 10 * time.Millisecond // how often stopGroup looks for the group to be gone
)

// runBounded runs the command as the leader of a new process group with its output going straight to the
// two files, and watches it: wall clock >= timeout, the two files together >= maxBytes, or more than maxProcs
// descendants stop it with that reason. Whatever happened, the whole group is then stopped (TERM, then KILL).
// RLIMIT_FSIZE = maxBytes is set in the child, so one file can never outgrow the cap between two polls. When a
// cap fired the two files are cut jointly to maxBytes. The error is non-nil only when the command cannot start.
func runBounded(sp runSpec) (runRecord, []string, error) {
	outPath := filepath.Join(sp.dir, "engine/stdout.txt")
	errPath := filepath.Join(sp.dir, "engine/stderr.txt")
	started := sp.now() // wall clock for the record, monotonic reading for the bounds
	wall := started
	out, err := os.Create(outPath)
	if err != nil {
		return runRecord{}, nil, osError(err, outPath)
	}
	defer out.Close()
	errf, err := os.Create(errPath)
	if err != nil {
		return runRecord{}, nil, osError(err, errPath)
	}
	defer errf.Close()

	argv := append([]string{sp.self, proc.HelperCommand, fmt.Sprintf("fsize=%d", sp.maxBytes), sp.argv[0]}, sp.argv...)
	cmd := &exec.Cmd{Path: sp.self, Args: argv, Dir: sp.dir, Env: sp.env, Stdout: out, Stderr: errf}
	proc.SetNewGroup(cmd)
	if err := cmd.Start(); err != nil {
		return runRecord{}, nil, osError(err, sp.argv[0])
	}
	pid := cmd.Process.Pid
	var group proc.Group
	group.Record(pid)
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()

	size := func() int64 {
		var n int64
		for _, f := range []*os.File{out, errf} {
			if fi, err := f.Stat(); err == nil {
				n += fi.Size()
			}
		}
		return n
	}
	reason := ""
	tick := time.NewTicker(pollEvery)
	defer tick.Stop()
wait:
	for {
		select {
		case <-exited:
			break wait
		case <-tick.C:
			switch {
			case sp.now().Sub(started) >= sp.timeout:
				reason = reasonTimeout
			case size() >= sp.maxBytes:
				reason = reasonOutput
			case max(0, processTree(pid)-1) > sp.maxProcs:
				reason = reasonProcs
			}
			if reason != "" {
				break wait
			}
		}
	}
	stopGroup(&group, pid, sp.now)
	<-exited
	code := exitCode(cmd.ProcessState)
	if reason == "" && size() >= sp.maxBytes {
		reason = reasonOutput
	}
	if reason != "" {
		budget := sp.maxBytes
		for _, f := range []*os.File{out, errf} {
			keep := budget
			if fi, err := f.Stat(); err == nil {
				keep = min(keep, fi.Size())
			}
			if err := f.Truncate(keep); err != nil {
				return runRecord{}, nil, osError(err, f.Name())
			}
			budget -= keep
		}
	}
	rec := runRecord{startedAt: isoUTC(wall), endedAt: isoUTC(sp.now()), durationMs: sp.now().Sub(started).Milliseconds()}
	if code >= 0 {
		rec.exitCode = &code
	} else {
		sig := -code
		rec.signal = &sig
	}
	var errs []string
	switch {
	case reason != "":
		errs = []string{reason}
	case code != 0:
		errs = []string{fmt.Sprintf("analyzer-exit:%d", code)}
	}
	return rec, errs, nil
}

// exitCode is Popen's returncode: the exit status, or minus the signal that killed the process.
func exitCode(ps *os.ProcessState) int {
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return -int(ws.Signal())
	}
	return ps.ExitCode()
}

// stopGroup signals the group TERM, gives it half a second to empty, then signals KILL. A group with no member
// left (or one the kill-safety guard refuses) ends it at once. The caller reaps the leader, so nothing waits after
// KILL.
func stopGroup(g *proc.Group, pid int, now func() time.Time) {
	if err := g.Signal(pid, syscall.SIGTERM); err != nil {
		return
	}
	for deadline := now().Add(500 * time.Millisecond); now().Before(deadline) && processTree(pid) > 0; {
		time.Sleep(stopPoll)
	}
	_ = g.Signal(pid, syscall.SIGKILL)
}
