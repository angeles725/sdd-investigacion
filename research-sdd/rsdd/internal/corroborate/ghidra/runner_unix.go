//go:build unix

package ghidra

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	pollInterval = 20 * time.Millisecond
	termGrace    = time.Second
	probeTimeout = 5 * time.Second
)

// runSpec is one sandboxed process: the launcher path (a /proc/self/fd entry of the locked Bubblewrap), the full
// argv, the whole environment, the staging directory as the working directory and the descriptors the child
// inherits as 3, 4, ... in order.
type runSpec struct {
	exe   string
	argv  []string
	env   []string
	dir   string
	extra []*os.File
}

// startError renders a launcher that could not start the way Python's OSError reads.
func startError(err error, exe string) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return osError(pe.Err, exe)
	}
	return err
}

// probe runs a short command and returns its exit code: -1 when it could not run to completion in time.
func (s runSpec) probe() (int, error) {
	cmd := s.command()
	if err := cmd.Start(); err != nil {
		return 0, startError(err, s.exe)
	}
	var g proc.Group
	g.Record(cmd.Process.Pid)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		return cmd.ProcessState.ExitCode(), nil
	case <-time.After(probeTimeout):
		stopGroup(&g, cmd.Process.Pid, done)
		return -1, nil
	}
}

func (s runSpec) command() *exec.Cmd {
	return &exec.Cmd{Path: s.exe, Args: s.argv, Dir: s.dir, Env: s.env, ExtraFiles: s.extra,
		SysProcAttr: &syscall.SysProcAttr{Setsid: true}}
}

// stopGroup is TERM, a short wait for the leader, then KILL: the guard in core/proc refuses any group that is not
// the child's recorded one, and a group already gone ends the stop.
func stopGroup(g *proc.Group, pid int, done <-chan error) {
	if err := g.Signal(pid, syscall.SIGTERM); err != nil && !errors.Is(err, proc.ErrGroupGone) {
		_ = syscall.Kill(pid, syscall.SIGKILL) // the leader only
	}
	select {
	case <-done:
		return
	case <-time.After(termGrace):
	}
	if err := g.Signal(pid, syscall.SIGKILL); err != nil && !errors.Is(err, proc.ErrGroupGone) {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	<-done
}

// logFile opens a diagnostic file without following symlinks; it must be a regular file. The descriptor is
// meaningless (0) alongside an error.
func logFile(path string, flags int) (int, error) {
	fd, err := syscall.Open(path, flags|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0o600)
	if err != nil {
		return 0, fmt.Errorf("unsafe diagnostic file: %s", filepath.Base(path))
	}
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil || st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		_ = syscall.Close(fd)
		return 0, fmt.Errorf("unsafe diagnostic file: %s", filepath.Base(path))
	}
	return fd, nil
}

// diagnosticSize sums the sizes of the diagnostic files, each opened safely.
func diagnosticSize(paths []string) (int64, error) {
	var total int64
	for _, p := range paths {
		fd, err := logFile(p, syscall.O_RDONLY)
		if err != nil {
			return 0, err
		}
		var st syscall.Stat_t
		err = syscall.Fstat(fd, &st)
		_ = syscall.Close(fd)
		if err != nil {
			return 0, err
		}
		total += st.Size
	}
	return total, nil
}

// truncateLogs cuts the diagnostic files jointly to budget bytes, in order.
func truncateLogs(paths []string, budget int64) error {
	for _, p := range paths {
		fd, err := logFile(p, syscall.O_RDWR)
		if err != nil {
			return err
		}
		var st syscall.Stat_t
		if err = syscall.Fstat(fd, &st); err == nil {
			keep := min(st.Size, budget)
			err = syscall.Ftruncate(fd, keep) // a no-op when nothing is cut
			budget -= keep
		}
		_ = syscall.Close(fd)
		if err != nil {
			return err
		}
	}
	return nil
}

// reap collects every child of the group (the subreaper adopted the orphans) so no zombie or stray descendant
// outlives the run.
func reap(pgid int) {
	for {
		var ws syscall.WaitStatus
		_, err := syscall.Wait4(-pgid, &ws, 0, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil {
			return
		}
	}
}

// bounded runs the sandbox with a wall-clock bound and a joint cap on the four diagnostic files (stdout, stderr
// and Ghidra's two logs), then stops and reaps the whole process group even after a normal exit. It returns the
// run record and the typed errors. An unsafe diagnostic file (a symlink the sandbox planted) stops the run and is
// reported as `unsafe-diagnostic`, or as a hard error when it is found after the run.
func (j *job) bounded(s runSpec) (map[string]any, []string, error) {
	stage := j.stage
	stdoutP, stderrP := filepath.Join(stage, "logs/stdout.txt"), filepath.Join(stage, "logs/stderr.txt")
	logs := []string{stdoutP, stderrP, filepath.Join(stage, "logs/application.log"), filepath.Join(stage, "logs/script.log")}
	started := j.s.Clock()
	fds := [2]int{}
	for i, p := range []string{stdoutP, stderrP} {
		fd, err := logFile(p, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL)
		if err != nil {
			for _, open := range fds[:i] {
				_ = syscall.Close(open)
			}
			return nil, nil, err
		}
		fds[i] = fd
	}
	out, errf := os.NewFile(uintptr(fds[0]), stdoutP), os.NewFile(uintptr(fds[1]), stderrP)
	defer out.Close()
	defer errf.Close()
	setSubreaper()
	cmd := s.command()
	cmd.Stdout, cmd.Stderr = out, errf
	if err := cmd.Start(); err != nil {
		return nil, nil, startError(err, s.exe)
	}
	pid := cmd.Process.Pid
	var g proc.Group
	g.Record(pid)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	reason := ""
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	deadline := time.NewTimer(seconds(j.cfg.timeout)) // supervision uses timers; the recorded stamps use the injected clock
	defer deadline.Stop()
loop:
	for {
		select {
		case <-done:
			break loop
		case <-deadline.C:
			reason = "wall-timeout"
		case <-ticker.C:
			diagnostic, derr := diagnosticSize(logs)
			if derr != nil {
				reason, diagnostic = "unsafe-diagnostic", 0
			}
			if diagnostic > int64(j.cfg.maxDiagnostic) {
				reason = "diagnostic-cap"
			}
		}
		if reason != "" {
			stopGroup(&g, pid, done)
			break loop
		}
	}
	rc := cmd.ProcessState.ExitCode()
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		rc = -int(ws.Signal())
	}
	_ = g.Signal(pid, syscall.SIGTERM)
	time.Sleep(50 * time.Millisecond)
	_ = g.Signal(pid, syscall.SIGKILL)
	reap(pid)

	diagnostic, err := diagnosticSize(logs)
	if err != nil {
		return nil, nil, err
	}
	if reason == "" && diagnostic > int64(j.cfg.maxDiagnostic) {
		reason = "diagnostic-cap"
	}
	if err := truncateLogs(logs, int64(j.cfg.maxDiagnostic)); err != nil {
		return nil, nil, err
	}
	ended := j.s.Clock()
	run := runRecord(started, ended, rc)
	var errs []string
	switch {
	case reason != "":
		errs = []string{reason}
	case rc != 0:
		errs = []string{fmt.Sprintf("analyzer-exit:%d", rc)}
	}
	return run, errs, nil
}

// seconds converts a cap in seconds to a Duration without overflowing.
func seconds(n int) time.Duration {
	const limit = 1 << 30
	return time.Duration(min(n, limit)) * time.Second
}
