package kitmaint

import (
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The bash had no bound on any child; a run that never ends is the only thing a ceiling can change.
const (
	ChildCeiling = 10 * time.Minute
	maxBytes     = 64 << 20
)

// Res is one finished child: stdout, stderr and the shell's exit code (127 not runnable, 124 timed out).
type Res struct {
	Out, Err string
	RC       int
}

// OK is rc 0.
func (r Res) OK() bool { return r.RC == 0 }

// Runner runs the git and gh children of a kit tool. Every field is injected, so a test (or the merge train) owns
// the clock, the sleeping and the signal polling.
type Runner struct {
	Env    []string            // the child environment
	Cwd    string              // what a relative directory is relative to
	Now    func() time.Time    // handed to the bounded runners
	Err    io.Writer           // retry notes and a failing child's stderr
	Getenv func(string) string // KIT_RETRY_SLEEP
	Sleep  func(time.Duration) // backoff
	Poll   func()              // called after every child: where a pending INT/TERM may end the run (nil: none)
}

func (r *Runner) poll() {
	if r.Poll != nil {
		r.Poll()
	}
}

// Git is `git -C dir args` (an empty dir leaves git in the current directory).
func (r *Runner) Git(dir string, args ...string) Res {
	if dir != "" {
		dir = Abs(r.Cwd, dir)
	}
	out, err := git.Runner{Env: r.Env, Timeout: ChildCeiling, Now: r.Now}.Run(dir, args...)
	res := Res{Out: string(out)}
	var ee *git.ExitError
	switch {
	case err == nil:
	case errors.As(err, &ee):
		res.RC, res.Err = ee.Code, ee.Stderr
	case errors.Is(err, git.ErrTimeout):
		res.RC = 124
	default:
		res.RC = 127
	}
	r.poll()
	return res
}

// Gh is `(cd dir && gh args)`.
func (r *Runner) Gh(dir string, args ...string) Res {
	out, err := proc.Run(proc.Spec{
		Argv: append([]string{"gh"}, args...), Dir: dir, Env: append(append([]string(nil), r.Env...), "PWD="+dir),
		Timeout: ChildCeiling, MaxBytes: maxBytes, Now: r.Now,
	})
	r.poll()
	if err != nil {
		return Res{RC: 127}
	}
	res := Res{Out: string(out.Stdout), Err: string(out.Stderr), RC: out.ReturnCode}
	switch {
	case out.Reason == proc.ReasonTimeout:
		res.RC = 124
	case out.ReturnCode < 0:
		res.RC = 128 - out.ReturnCode
	}
	return res
}

// Retry is `kit_retry TRIES CMD` under the prefix of tool: up to tries attempts, KIT_RETRY_SLEEP (default 5) seconds
// times the attempt apart. The result carries the stdout of every attempt (a command substitution around kit_retry
// collects them all) and the stderr and rc of the last. quiet is the `2>/dev/null` around the bash call: attempt
// notes and a failing child's stderr are dropped. words is "$*" of the retried command.
func (r *Runner) Retry(tool string, tries int, words string, quiet bool, f func() Res) Res {
	var all Res
	for n := 1; ; n++ {
		res := f()
		all.Out += res.Out
		all.Err, all.RC = res.Err, res.RC
		if !quiet && res.RC != 0 && res.Err != "" {
			fmt.Fprint(r.Err, res.Err) // the child's stderr, which the bash inherited
		}
		if res.RC == 0 || n >= tries {
			return all
		}
		if !quiet {
			fmt.Fprintf(r.Err, "%s: retry %d/%d after rc=%d: %s\n", tool, n, tries, res.RC, words)
		}
		r.Sleep(time.Duration(IntOr(r.Getenv("KIT_RETRY_SLEEP"), 5)*n) * time.Second)
	}
}
