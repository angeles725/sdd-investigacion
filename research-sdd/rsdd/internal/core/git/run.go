package git

import (
	"errors"
	"fmt"
	"io/fs"
	"os/exec"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// DefaultTimeout bounds one git run when Runner.Timeout is 0.
const DefaultTimeout = 30 * time.Second

// DefaultMaxBytes caps one run's joint stdout+stderr when Runner.MaxBytes is 0.
const DefaultMaxBytes = 64 << 20

// Typed failures of Run, tested with errors.Is.
var (
	ErrMissing   = errors.New("git: not found")
	ErrTimeout   = errors.New("git: timed out")
	ErrOutputCap = errors.New("git: output cap reached")
)

// ExitError is a git run that exited non-zero. Code is the shell's exit code: the status, or 128+N for signal N.
type ExitError struct {
	Args   []string
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	msg := fmt.Sprintf("git %s: exit %d", strings.Join(e.Args, " "), e.Code)
	if line, _, _ := strings.Cut(e.Stderr, "\n"); line != "" {
		msg += ": " + line
	}
	return msg
}

// Runner runs git. The zero value runs "git" from an empty environment's default PATH, so callers pass theirs.
type Runner struct {
	// Bin is the git program, "git" when empty; a name without a slash is searched on Env's PATH.
	Bin string
	// Env is the whole environment of git; nothing is inherited.
	Env []string
	// Timeout and MaxBytes bound each run; 0 means DefaultTimeout / DefaultMaxBytes.
	Timeout  time.Duration
	MaxBytes int
	// Now is handed to core/proc; nil reads no clock.
	Now func() time.Time
}

// Run is `git -C <dir> <args>` (an empty dir leaves git in the current directory) and returns its stdout. On
// an *ExitError the stdout is still returned.
func (r Runner) Run(dir string, args ...string) ([]byte, error) {
	bin := r.Bin
	if bin == "" {
		bin = "git"
	}
	res, err := proc.Run(proc.Spec{
		Argv: append([]string{bin, "-C", dir}, args...), Env: r.Env,
		Timeout: r.timeout(), MaxBytes: r.maxBytes(), Now: r.Now,
	})
	switch {
	case errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist): // a *proc.SpawnError from the lookup
		return nil, fmt.Errorf("%w: %v", ErrMissing, err)
	case err != nil:
		return nil, fmt.Errorf("git: %w", err)
	case res.Reason == proc.ReasonTimeout:
		return res.Stdout, fmt.Errorf("%w after %v: git %s", ErrTimeout, r.timeout(), strings.Join(args, " "))
	case res.Reason == proc.ReasonOutputCap:
		return res.Stdout, fmt.Errorf("%w (%d bytes): git %s", ErrOutputCap, r.maxBytes(), strings.Join(args, " "))
	case res.ReturnCode != 0:
		code := res.ReturnCode
		if code < 0 {
			code = 128 - code
		}
		return res.Stdout, &ExitError{Args: args, Code: code, Stderr: string(res.Stderr)}
	}
	return res.Stdout, nil
}

func (r Runner) timeout() time.Duration {
	if r.Timeout == 0 {
		return DefaultTimeout
	}
	return r.Timeout
}

func (r Runner) maxBytes() int {
	if r.MaxBytes == 0 {
		return DefaultMaxBytes
	}
	return r.MaxBytes
}
