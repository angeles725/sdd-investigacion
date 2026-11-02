package gate

import (
	"errors"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The bash runs gentle-ai and the unbound `ghr` calls with no bound at all; a run that never ends is the only
// thing a ceiling can change, so it is generous. gh's bounded step keeps the script's own bound.
const (
	mgUnboundedCeiling = time.Hour
	mgMaxBytes         = 64 << 20
	mgGHBoundKnob      = "MERGE_GATE_GH_TIMEOUT"
	mgGHBoundDefault   = 30
)

// osMgRunner starts the real processes: git through core/git, gh's bounded step through core/gh, the rest
// through core/proc. Every child gets the caller's whole environment.
type osMgRunner struct{ s cli.Stdio }

func (o osMgRunner) Has(name string) bool {
	_, err := probe.New(o.s.Environ(), o.s.Cwd).LookPath(name)
	return err == nil
}

func (o osMgRunner) Git(dir string, args ...string) mgCmd {
	out, err := git.Runner{Env: o.s.Environ(), Now: o.s.Clock}.Run(dir, args...)
	c := mgCmd{Stdout: out}
	var ee *git.ExitError
	switch {
	case err == nil:
	case errors.As(err, &ee):
		c.RC = ee.Code
	case errors.Is(err, git.ErrTimeout):
		c.RC, c.Timeout = 124, true
	default:
		c.RC = 127
	}
	return c
}

func (o osMgRunner) GentleAI(args ...string) mgCmd { return o.run("", "gentle-ai", args) }

func (o osMgRunner) GH(dir string, args ...string) mgCmd { return o.run(dir, "gh", args) }

func (o osMgRunner) run(dir, bin string, args []string) mgCmd {
	env := o.s.Environ()
	if dir != "" {
		env = append(append([]string(nil), env...), "PWD="+o.absDir(dir))
	}
	res, err := proc.Run(proc.Spec{
		Argv: append([]string{bin}, args...), Dir: dir, Env: env,
		Timeout: mgUnboundedCeiling, MaxBytes: mgMaxBytes, Now: o.s.Clock,
	})
	if err != nil {
		return mgCmd{RC: 127}
	}
	c := mgCmd{Stdout: res.Stdout, Stderr: res.Stderr, RC: res.ReturnCode}
	switch {
	case res.Reason == proc.ReasonTimeout:
		c.RC, c.Timeout = 124, true
	case res.ReturnCode < 0:
		c.RC = 128 - res.ReturnCode
	}
	return c
}

func (o osMgRunner) GHBounded(dir string, args ...string) mgCmd {
	env := append(append([]string(nil), o.s.Environ()...), "PWD="+o.absDir(dir))
	rr, err := gh.Run(gh.Options{Env: env, Dir: dir, Knob: mgGHBoundKnob, Default: mgGHBoundDefault, Now: o.s.Clock}, args...)
	c := mgCmd{Stdout: rr.Stdout, Stderr: rr.Stderr, RC: rr.RC, Timeout: rr.State == gh.StateTimeout}
	if err != nil && c.RC == 0 {
		c.RC = 1
	}
	return c
}

// absDir is the directory the child's PWD names, as the bash `cd` leaves it: the logical path, made absolute.
func (o osMgRunner) absDir(dir string) string {
	if strings.HasPrefix(dir, "/") {
		return filepath.Clean(dir)
	}
	return filepath.Join(o.s.Cwd, dir)
}
