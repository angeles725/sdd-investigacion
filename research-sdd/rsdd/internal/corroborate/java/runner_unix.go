//go:build unix

package java

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// run_adapter, ported. core/proc.Run is not used for the adapters because the legacy contract polls the files
// the adapter writes (count and bytes under engines/<name>) while it runs and stops the group the moment a cap is
// passed, which Run has no hook for; the process-group guard (proc.Group, proc.SetNewGroup) is the one core/proc
// exports, so no group is ever signalled outside it. The per-file size limit is lowered in the child through the
// same re-exec helper core/proc uses (`rsdd __exec fsize=N`).

const pollInterval = 50 * time.Millisecond

// budget is the diagnostics byte budget shared by stdout and stderr.
type budget struct {
	mu        sync.Mutex
	remaining int64
}

func (b *budget) take(n int) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	kept := min(int64(n), b.remaining)
	b.remaining -= kept
	return int(kept)
}

// drainDiagnostic is drain_diagnostic: copy a pipe to a raw file within the shared budget until EOF or until the
// caller closes the pipe at the end of the run. Bytes past the budget are read and dropped so the child never
// blocks, and exceeded is set.
func drainDiagnostic(src *os.File, target string, b *budget, exceeded *atomic.Bool) {
	out, err := os.Create(target)
	if err != nil {
		return
	}
	defer out.Close()
	buf := make([]byte, 64*1024)
	for {
		n, rerr := src.Read(buf)
		// A read of n == 0 bytes needs no guard: take(0) keeps 0 (the budget is never negative), the write is empty and
		// kept == n, so exceeded is untouched. The unguarded form has no n == 0 boundary to flip.
		kept := b.take(n)
		_, _ = out.Write(buf[:kept])
		if kept != n {
			exceeded.Store(true)
		}
		if rerr != nil {
			return
		}
	}
}

// helperArgv wraps command in the rlimit helper: fsize lowers RLIMIT_FSIZE to maxBytes before the exec.
func (e *env) helperArgv(command []string, maxBytes int64) (path string, args []string, err error) {
	if e.helper == nil {
		return command[0], command, nil
	}
	helper, err := e.helper()
	if err != nil {
		return "", nil, fail("cannot locate the rsdd binary that lowers the adapter's file size limit: %v", err)
	}
	args = append([]string{helper, proc.HelperCommand, "fsize=" + strconv.FormatInt(maxBytes, 10), command[0]}, command...)
	return helper, args, nil
}

func returnCode(ps *os.ProcessState) int {
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return -int(ws.Signal())
	}
	return ps.ExitCode()
}

// runAdapter is run_adapter: the command runs as its own process-group leader in cwd with exactly environment;
// its stdout and stderr land in engineRoot/{stdout,stderr}.raw.txt within maxBytes together; the run is stopped
// when the files below engineRoot pass maxFiles/maxBytes, when the diagnostics overflow, or when the timeout
// (less a 250 ms cleanup margin) is reached.
func (e *env) runAdapter(command []string, cwd, engineRoot string, environment []string, timeoutSec int, maxFiles, maxBytes int64) (outcome, error) {
	startedWall := e.s.Clock()
	timeout := time.Duration(timeoutSec) * time.Second
	deadline, cancelDeadline := context.WithTimeout(context.Background(), timeout)
	defer cancelDeadline()
	cleanup, cancelCleanup := context.WithTimeout(context.Background(), timeout-min(250*time.Millisecond, timeout/4))
	defer cancelCleanup()

	// Popen raised for a program that cannot start; behind the helper the failure would only be an exit code.
	if fi, err := os.Stat(command[0]); err != nil {
		return outcome{}, osFailure(err, command[0])
	} else if !fi.Mode().IsRegular() || !canExec(command[0]) {
		return outcome{}, osFailure(syscall.EACCES, command[0])
	}
	path, args, err := e.helperArgv(command, maxBytes)
	if err != nil {
		return outcome{}, err
	}
	cmd := &exec.Cmd{Path: path, Args: args, Dir: cwd, Env: environment}
	proc.SetNewGroup(cmd)
	var readers, writers [2]*os.File
	for i := range readers {
		if readers[i], writers[i], err = os.Pipe(); err != nil {
			closeFiles(readers[0], writers[0])
			return outcome{}, osFailure(err, "")
		}
	}
	cmd.Stdout, cmd.Stderr = writers[0], writers[1]
	if err := cmd.Start(); err != nil {
		closeFiles(readers[0], readers[1], writers[0], writers[1])
		return outcome{}, osFailure(err, command[0])
	}
	closeFiles(writers[0], writers[1])
	var group proc.Group
	group.Record(cmd.Process.Pid)
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	hasExited := func() bool {
		select {
		case <-exited:
			return true
		default:
			return false
		}
	}

	b := &budget{remaining: maxBytes}
	var exceeded atomic.Bool
	var wg sync.WaitGroup
	for i, target := range []string{"stdout.raw.txt", "stderr.raw.txt"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			drainDiagnostic(readers[i], engineRoot+"/"+target, b, &exceeded)
		}()
	}

	stopGroup := func() {
		if err := group.Signal(cmd.Process.Pid, syscall.SIGTERM); err != nil {
			if !errors.Is(err, proc.ErrGroupGone) {
				_ = cmd.Process.Kill() // the guard refused the group: stop the leader through its own handle
			}
			return
		}
		time.Sleep(min(pollInterval, remaining(deadline)))
		_ = group.Signal(cmd.Process.Pid, syscall.SIGKILL)
		if !hasExited() {
			select {
			case <-exited:
			case <-time.After(remaining(deadline)):
				_ = cmd.Process.Kill()
			}
		}
	}

	state := "running"
	var runErr error
	for !hasExited() {
		files, size, serr := scanFiles(engineRoot, maxFiles, maxBytes)
		if serr != nil {
			runErr = serr
			break
		}
		if exceeded.Load() || files > maxFiles || size > maxBytes {
			state = "cap_exceeded"
			stopGroup()
			break
		}
		if cleanup.Err() != nil {
			state = "timeout"
			stopGroup()
			break
		}
		select {
		case <-exited:
		case <-time.After(pollInterval):
		}
	}
	stopGroup()
	<-exited
	// The pipes reach EOF once every writer is gone. One that left the group and still holds a pipe cannot hold
	// the run open: after a short idle wait the read ends are closed, which ends the copies.
	joined := make(chan struct{})
	go func() { wg.Wait(); close(joined) }()
	select {
	case <-joined:
	case <-time.After(min(2*pollInterval, remaining(deadline))):
	}
	closeFiles(readers[0], readers[1])
	<-joined
	if runErr != nil {
		return outcome{}, runErr
	}
	returncode := returnCode(cmd.ProcessState)
	files, size, err := scanFiles(engineRoot, maxFiles, maxBytes)
	if err != nil {
		return outcome{}, err
	}
	if state == "running" && (exceeded.Load() || files > maxFiles || size > maxBytes) {
		state = "cap_exceeded"
	}
	ended := e.s.Clock()
	if state == "running" {
		state = "failed"
		if returncode == 0 {
			state = "success"
		}
	}
	return outcome{
		status: state, returncode: returncode, diagnosticsTruncated: exceeded.Load(),
		startedAt: isoZ(startedWall), endedAt: isoZ(ended), durationMS: ended.Sub(startedWall).Milliseconds(),
	}, nil
}

// remaining is max(0, deadline - now).
func remaining(ctx context.Context) time.Duration {
	d, ok := ctx.Deadline()
	if !ok {
		return 0
	}
	return max(0, time.Until(d))
}

func closeFiles(fs ...*os.File) {
	for _, f := range fs {
		if f != nil {
			_ = f.Close()
		}
	}
}
