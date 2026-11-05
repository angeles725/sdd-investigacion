package fetchdoc

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner"
)

// settle is how long the seam waits after its command, so a signal the command sent to this very process has been
// delivered and handled before the run looks at it (the legacy shell took its trap synchronously).
const settle = 50 * time.Millisecond

// seam is the TEST-ONLY hook of the legacy script: with FETCHDOC_TEST_SEAM=1 and FETCHDOC_TEST_AT=<point>, the
// shell text FETCHDOC_TEST_CMD runs at exactly that point of the run, so a signal or a concurrent writer can be
// injected deterministically (no sleeps in the tests). Points: "install" (the start of the install of new bytes)
// and "after-fork" (right after a tracked stage starts). It is inert without FETCHDOC_TEST_SEAM=1.
//
// The command runs in `bash -c` with the script variables it may name exported (DEST, SDIR, REPLACE; HTML in the stages that stage a page), and a
// literal "$$" replaced by the pid of this process (in the shell script it was the script's own pid).
type seam struct {
	at, cmd string
	d       Deps
}

// newSeam returns nil when the seam is not opted into.
func newSeam(d Deps) *seam {
	if d.Env("FETCHDOC_TEST_SEAM") != "1" {
		return nil
	}
	return &seam{at: d.Env("FETCHDOC_TEST_AT"), cmd: d.Env("FETCHDOC_TEST_CMD"), d: d}
}

// fire runs the command when point is the configured one. vars are exported to it as KEY=VALUE.
func (s *seam) fire(point string, vars []string) {
	if s == nil || s.at != point {
		return
	}
	cmd := strings.ReplaceAll(s.cmd, "$$", strconv.Itoa(s.d.Pid))
	if cmd == "" {
		cmd = ":"
	}
	r := runner.Exec{Env: append(append([]string(nil), s.d.Environ...), vars...), Look: s.d.Look}
	r.Run(context.Background(), []string{"bash", "-c", cmd}, s.d.Out, s.d.Err)
	time.Sleep(settle)
}
