//go:build unix

package proc

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// defaultPath is os.defpath, which Popen searches when Env has no PATH.
const defaultPath = "/bin:/usr/bin"

// Run runs spec.Argv as the leader of a new process group and returns once
// it has exited. A timeout or the output cap stops the whole group (TERM,
// grace, KILL, grace); after a normal exit the same stop clears any
// leftover group member. The error is non-nil only for an invalid spec, a
// program that cannot be started, or a group the guard refused to stop.
func Run(spec Spec) (Result, error) {
	if err := spec.validate(); err != nil {
		return Result{}, err
	}
	if _, err := parseLimits(formatLimits(spec.Limits)); err != nil {
		return Result{}, fmt.Errorf("%w: %v", ErrInvalidSpec, err)
	}
	path, err := resolve(spec.Argv[0], spec.Dir, spec.Env)
	if err != nil {
		return Result{}, &SpawnError{Path: spec.Argv[0], Err: err}
	}
	cmd := command(spec, path)
	c := newCapture(spec.MaxBytes)
	readers, writers, err := attachPipes(cmd)
	if err != nil {
		return Result{}, err
	}
	res := Result{Started: spec.now()}
	if err := cmd.Start(); err != nil {
		closeAll(readers[0], readers[1], writers[0], writers[1])
		return Result{}, &SpawnError{Path: spec.Argv[0], Err: err}
	}
	closeAll(writers[0], writers[1])
	var g Group
	g.Record(cmd.Process.Pid)
	drained := drain(c, readers)
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()

	res.Reason = watch(exited, c.hit, spec.Timeout)
	stopErr := stopGroup(&g, cmd.Process.Pid, spec.grace())
	if stopErr != nil {
		_ = cmd.Process.Kill() // the leader only, through its pidfd-backed handle
	}
	<-exited
	finishDrain(readers, drained, spec.grace())

	if res.Reason == "" && c.reached() {
		res.Reason = ReasonOutputCap
	}
	res.Stdout, res.Stderr = c.output()
	res.ReturnCode = returnCode(cmd.ProcessState)
	res.Ended = spec.now()
	res.Duration = res.Ended.Sub(res.Started)
	if stopErr != nil {
		return res, fmt.Errorf("proc: stop process group: %w", stopErr)
	}
	return res, nil
}

// command builds the exec.Cmd: the program itself, or the helper that
// lowers the limits and then execs it with the same argv.
func command(spec Spec, path string) *exec.Cmd {
	cmd := &exec.Cmd{Path: path, Args: spec.Argv, Dir: spec.Dir, Env: spec.Env}
	if len(spec.Limits) > 0 {
		cmd.Path = spec.Helper
		cmd.Args = append([]string{spec.Helper, HelperCommand, formatLimits(spec.Limits), path}, spec.Argv...)
	}
	SetNewGroup(cmd)
	return cmd
}

// resolve finds the program the way Popen does with an explicit env: a name
// with a slash is taken as is (relative to dir), anything else is searched
// on env's PATH. Checking before the start keeps a missing program a typed
// SpawnError on the helper path too, instead of a helper exit 127.
func resolve(name, dir string, env []string) (string, error) {
	if strings.Contains(name, "/") {
		return name, executable(name, dir)
	}
	search := defaultPath
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			search = v
		}
	}
	for _, d := range filepath.SplitList(search) {
		p := filepath.Join(d, name)
		if d == "" {
			p = "./" + name
		}
		if executable(p, dir) == nil {
			return p, nil
		}
	}
	return "", exec.ErrNotFound
}

// executable reports whether path (relative to dir) is an executable regular file.
func executable(path, dir string) error {
	if !filepath.IsAbs(path) {
		path = filepath.Join(dir, path)
	}
	fi, err := os.Stat(path)
	switch {
	case err != nil:
		return err
	case !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0:
		return fmt.Errorf("%s: %w", path, os.ErrPermission)
	}
	return nil
}

// attachPipes gives cmd its own stdout and stderr pipes; the parent closes
// the write ends after Start and drains the read ends.
func attachPipes(cmd *exec.Cmd) (readers, writers [2]*os.File, err error) {
	for i := range readers {
		if readers[i], writers[i], err = os.Pipe(); err != nil {
			closeAll(readers[0], writers[0])
			return readers, writers, fmt.Errorf("proc: pipe: %w", err)
		}
	}
	cmd.Stdout, cmd.Stderr = writers[0], writers[1]
	return readers, writers, nil
}

func closeAll(fs ...*os.File) {
	for _, f := range fs {
		if f != nil {
			_ = f.Close()
		}
	}
}

// drain copies each pipe into the capture until EOF; the returned channel
// closes when both are done.
func drain(c *capture, readers [2]*os.File) <-chan struct{} {
	var wg sync.WaitGroup
	for i, r := range readers {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = io.Copy(c.stream(i), r) }()
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	return done
}

// finishDrain waits up to grace for both pipes to reach EOF. A process that
// left the group and still holds a pipe cannot hold Run open: once grace
// runs out, a read deadline in the past ends the copy.
func finishDrain(readers [2]*os.File, drained <-chan struct{}, grace time.Duration) {
	select {
	case <-drained:
	case <-time.After(grace):
		for _, r := range readers {
			_ = r.SetReadDeadline(time.Unix(1, 0))
		}
		<-drained
	}
	closeAll(readers[0], readers[1])
}

// watch waits for the first of: the leader's exit, the timeout, the cap.
func watch(exited, hit <-chan struct{}, timeout time.Duration) string {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-exited:
		return ""
	case <-timer.C:
		return ReasonTimeout
	case <-hit:
		return ReasonOutputCap
	}
}

// stopGroup is run_bounded's stop_group through the guard: TERM the group,
// wait up to grace for it to empty, then KILL and wait again. A group that
// is already gone ends the stop.
func stopGroup(g *Group, pid int, grace time.Duration) error {
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL} {
		err := g.Signal(pid, sig)
		if errors.Is(err, ErrGroupGone) {
			return nil
		}
		if err != nil {
			return err
		}
		waitEmpty(pid, grace)
	}
	return nil
}

// waitEmpty polls until group pgid has no member or grace runs out.
func waitEmpty(pgid int, grace time.Duration) {
	expired := time.After(grace)
	for GroupAlive(pgid) {
		select {
		case <-expired:
			return
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// returnCode maps a wait status to Popen's convention.
func returnCode(ps *os.ProcessState) int {
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return -int(ws.Signal())
	}
	return ps.ExitCode()
}
