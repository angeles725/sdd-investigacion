package consumers

import (
	"errors"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// The bounds of one git child. They are variables so that a test can lower them instead of waiting for the real
// ones; nothing else assigns them.
var (
	childTimeout  = kitmaint.ChildCeiling
	childMaxBytes = 64 << 20
)

// gitRunner is the only way this command runs git: the caller's environment without the variables that would
// point git at another repository than the one named by -C, and bounded in time and output.
func gitRunner(s cli.Stdio) git.Runner {
	return git.Runner{Env: git.WithoutSelectors(s.Environment()), Timeout: childTimeout, MaxBytes: childMaxBytes, Now: s.Clock}
}

// gitError is the outcome of a git run that did not complete, or nil when err is nil. A non-zero exit is not
// decided here: the caller says what each command's exit code means.
func gitError(err error, sub, dir string) (code int, out *outcome) {
	var ee *git.ExitError
	switch {
	case err == nil:
		return 0, nil
	case errors.As(err, &ee):
		return ee.Code, nil
	case errors.Is(err, git.ErrMissing):
		return 0, degraded(stateNoGit)
	case errors.Is(err, git.ErrTimeout):
		return 0, &outcome{err: fmt.Sprintf(stateGitTimeout, sub, childTimeout, dir), rc: cli.ExitOperational}
	case errors.Is(err, git.ErrOutputCap):
		return 0, &outcome{err: fmt.Sprintf(stateGitCap, sub, childMaxBytes, dir), rc: cli.ExitOperational}
	}
	return 0, &outcome{err: fmt.Sprintf(stateGitFailed, sub, err, dir), rc: cli.ExitOperational}
}

// stderrDegraded is the degraded outcome of a listing that exited 0 and still wrote on stderr: git's first line
// and the number of lines after it, so a reader knows what was not shown.
func stderrDegraded(stderr []byte) *outcome {
	lines := strings.Split(strings.TrimRight(string(stderr), "\n"), "\n")
	return degraded(fmt.Sprintf(stateListStderr, lines[0], len(lines)-1))
}
