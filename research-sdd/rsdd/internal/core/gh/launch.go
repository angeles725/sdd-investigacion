package gh

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// DefaultMaxBytes caps gh's joint stdout+stderr when Options.MaxBytes is 0.
const DefaultMaxBytes = 16 << 20

// killGrace is how long a TERMed gh has before the KILL: `timeout -k 2` and the bash watchdog's 2 s.
const killGrace = 2 * time.Second

// Options configure one gh call. The zero value runs "gh" from PATH in the current directory with an empty
// environment, so callers pass their environ.
type Options struct {
	// Bin is the gh program, "gh" when empty; a name without a slash is searched on Env's PATH.
	Bin string
	// Env is the caller's environment; gh gets it without GH_REPO and with GH_PROMPT_DISABLED=1.
	Env []string
	// Dir is the directory gh runs in; "" is the current one.
	Dir string
	// Knob and Default select the bound (see ResolveBound): GHV_BOUND_ENV and GHV_DEFAULT_BOUND.
	Knob    string
	Default int
	// MaxBytes caps the joint output, DefaultMaxBytes when 0.
	MaxBytes int
	// Now is handed to core/proc; nil reads no clock.
	Now func() time.Time
}

// outcome is one bounded run classified up to, not including, the meaning of a zero exit.
type outcome struct {
	res   proc.Result
	bound Bound
	rc    int
	state State // "" when gh exited 0 within its bounds
}

// launch runs gh with args under the resolved bound. The error is non-nil only for StateProbeFailed.
func (o Options) launch(args []string) (outcome, error) {
	bin := o.Bin
	if bin == "" {
		bin = "gh"
	}
	maxBytes := o.MaxBytes
	if maxBytes == 0 {
		maxBytes = DefaultMaxBytes
	}
	out := outcome{bound: ResolveBound(o.Env, o.Knob, o.Default)}
	res, err := proc.Run(proc.Spec{
		Argv: append([]string{bin}, args...), Dir: o.Dir, Env: cleanEnv(o.Env),
		Timeout: time.Duration(out.bound.Seconds) * time.Second, MaxBytes: maxBytes, Grace: killGrace, Now: o.Now,
	})
	var spawn *proc.SpawnError
	switch {
	case errors.As(err, &spawn):
		return spawnFailed(spawn, o.Dir, out), nil
	case err != nil:
		out.state = StateProbeFailed
		return out, fmt.Errorf("gh: %w", err)
	}
	out.res, out.rc = res, shellRC(res)
	switch {
	case res.Reason == proc.ReasonOutputCap:
		out.state = StateOutputCap
	case out.rc == 124:
		out.state = StateTimeout
	case out.rc != 0:
		out.state = StateError
	}
	return out, nil
}

// spawnFailed classifies a gh that never started in the bash order: a name not on PATH is GH_MISSING (the
// `command -v` check comes first, no bound applied); a directory it cannot enter is the subshell's `cd` failing
// (rc 1); a path that is not there is GH_MISSING too; a program that cannot be executed is env(1)'s 126.
func spawnFailed(err *proc.SpawnError, dir string, out outcome) outcome {
	notOnPath := errors.Is(err, exec.ErrNotFound)
	switch {
	case !notOnPath && !isDir(dir):
		out.state, out.rc = StateError, 1
	case notOnPath || errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrPermission):
		out.state, out.rc, out.bound = StateMissing, 0, Bound{}
	default:
		out.state, out.rc = StateError, 126
	}
	return out
}

// isDir reports whether dir ("" is the current directory) can be entered as a directory.
func isDir(dir string) bool {
	fi, err := os.Stat(dir)
	return dir == "" || (err == nil && fi.IsDir())
}

// shellRC is the exit code a shell reports for res: 124 when the bound fired (timeout's code), 128+N for a
// signal, else the exit status.
func shellRC(res proc.Result) int {
	switch {
	case res.Reason == proc.ReasonTimeout:
		return 124
	case res.ReturnCode < 0:
		return 128 - res.ReturnCode
	}
	return res.ReturnCode
}

// cleanEnv is `env -u GH_REPO GH_PROMPT_DISABLED=1` over environ.
func cleanEnv(environ []string) []string {
	out := slices.DeleteFunc(slices.Clone(environ), func(kv string) bool {
		k, _, _ := strings.Cut(kv, "=")
		return k == "GH_REPO" || k == "GH_PROMPT_DISABLED"
	})
	return append(out, "GH_PROMPT_DISABLED=1")
}
