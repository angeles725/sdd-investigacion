//go:build linux || darwin

package carve

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	pollEvery   = 10 * time.Millisecond
	stderrKeep  = 4096
	drainWait   = 2 * time.Second
	reasonTime  = "timeout"
	reasonProcs = "process cap"
)

// launchWorker runs the command in a new process group under the wall clock and process-count caps, with core
// dumps off and the address space limited, and returns nil only when it exited 0. A cap kills the group; a
// failure carries the worker's stderr (its first 4 KiB), which is how the worker's own message reaches the
// caller. The rlimits are lowered in the child through the rsdd re-exec helper, as Go has no pre-exec hook.
func launchWorker(sp launchSpec) error {
	if sp.now == nil {
		return errors.New("no clock available")
	}
	limits := fmt.Sprintf("core=0,as=%d", sp.memory)
	argv := append([]string{sp.self, proc.HelperCommand, limits, sp.argv[0]}, sp.argv...)
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	cmd := &exec.Cmd{Path: sp.self, Args: argv, Dir: sp.dir, Env: sp.env, Stderr: w}
	proc.SetNewGroup(cmd)
	if err := cmd.Start(); err != nil {
		_ = r.Close()
		_ = w.Close()
		return err
	}
	_ = w.Close()
	var group proc.Group
	group.Record(cmd.Process.Pid)

	detail := make(chan string, 1)
	go func() {
		head, _ := io.ReadAll(io.LimitReader(r, stderrKeep))
		_, _ = io.Copy(io.Discard, r) // keep draining so a chatty worker never blocks on a full pipe
		detail <- string(head)
	}()
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()

	reason, started := "", sp.now()
	tick := time.NewTicker(pollEvery)
	defer tick.Stop()
wait:
	for {
		select {
		case <-exited:
			break wait
		case <-tick.C:
			if sp.now().Sub(started) >= sp.timeout {
				reason = reasonTime
			} else if max(0, processTree(cmd.Process.Pid)-1) > sp.maxProcs {
				reason = reasonProcs
			}
			if reason != "" {
				_ = group.Signal(cmd.Process.Pid, syscall.SIGKILL)
				break wait
			}
		}
	}
	<-exited
	var text string
	select {
	case text = <-detail:
	case <-time.After(drainWait):
		_ = r.Close()
	}
	if code := cmd.ProcessState.ExitCode(); reason == "" && code == 0 {
		return nil
	}
	if reason != "" {
		return fmt.Errorf("%s", reason)
	}
	msg := "isolated worker failed"
	if d := strings.TrimSpace(strings.ToValidUTF8(text, "�")); d != "" {
		msg += ": " + d
	}
	return fmt.Errorf("%s", msg)
}
