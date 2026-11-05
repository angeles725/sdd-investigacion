package kitmaint

import (
	"bufio"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A signal to the group reaches what the command started, not only the command: the grandchild must die too.
func TestSignalGroupReachesTheGrandchild(t *testing.T) {
	c := exec.Command("sh", "-c", "sleep 30 & echo $!; wait")
	ProcAttr(c)
	out, err := c.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = syscall.Kill(pid, syscall.SIGKILL) }() // never leave it behind if the group signal missed it
	SignalGroup(c, false)
	_ = c.Wait()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Errorf("the grandchild %d survived SignalGroup", pid)
}

func TestRetryableErrors(t *testing.T) {
	for _, c := range []struct {
		err  error
		want bool
	}{
		{syscall.EWOULDBLOCK, true}, {syscall.EINTR, true}, {syscall.EBADF, false}, {syscall.EINVAL, false}, {nil, false},
	} {
		if got := retryable(c.err); got != c.want {
			t.Errorf("retryable(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}
