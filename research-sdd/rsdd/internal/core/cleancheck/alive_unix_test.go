//go:build unix

package cleancheck

import (
	"errors"
	"syscall"
)

// pidGone reports that no process has this pid any more (kill -0 finds none).
func pidGone(pid int) bool { return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) }
