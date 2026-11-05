package fetchdoc

import (
	"io"
	"os"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner"
)

// Deps is everything Execute needs from the world, so a test can run the command in process with a scripted
// runner and a fake clock.
type Deps struct {
	Out, Err io.Writer
	// Env reads one variable of the caller's environment; Environ is the whole of it (KEY=VALUE) and is what
	// children inherit. Environ must not be nil: a child with no PATH finds nothing.
	Env     func(string) string
	Environ []string
	Now     func() time.Time
	// Pid names part files ("<dest>.fetchdoc-part.<pid>") and replaces "$$" in the test seam.
	Pid int
	// TmpDir is where the web snapshot's HTML is staged ($TMPDIR, else /tmp).
	TmpDir string
	// Run starts the external tools; Look resolves a name on the caller's PATH. Have is derived from Look.
	Run  runner.Runner
	Look func(name string) (string, error)
	// Signals delivers INT/TERM (nil: none).
	Signals <-chan os.Signal
	// Alive overrides the liveness test of the stale-part sweep (nil: the real one).
	Alive func(pid string) bool
}

// have is `command -v name`.
func (d Deps) have(name string) bool { _, err := d.Look(name); return err == nil }

// ProductionDeps builds the Deps of the real command from the process Stdio.
func ProductionDeps(s cli.Stdio, pid int, sigs <-chan os.Signal) Deps {
	environ := s.Environment()
	if environ == nil { // a Stdio without an environment (a test): the children still need a PATH
		environ = []string{"PATH=" + s.Env("PATH")}
	}
	look := probe.New(environ, s.Cwd).LookPath
	tmp := s.Env("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	return Deps{
		Out: s.Out, Err: s.Err, Env: s.Env, Environ: environ, Now: s.Clock, Pid: pid, TmpDir: tmp,
		Run: runner.Exec{Env: environ, Look: look}, Look: look, Signals: sigs,
	}
}
