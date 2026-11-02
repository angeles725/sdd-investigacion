package ensureremote

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Cmd is one external program run (git, or bash for the secret scanner).
type Cmd struct {
	Argv    []string
	Env     []string // the whole environment of the program; nothing is inherited
	Timeout time.Duration
}

// Out is what a run produced. RC is the shell's exit status (124 = the bound was hit, 128+N = signal N); Err is
// non-nil only when the program could not be started, and then RC is 127.
type Out struct {
	RC             int
	Stdout, Stderr []byte
	Err            error
}

// Runner runs one external program. Tests inject a fake, so no process starts in them.
type Runner func(Cmd) Out

// GH is the gh seam: the bounded runner and the visibility probe of core/gh.
type GH struct {
	Run   func(gh.Options, ...string) (gh.RunResult, error)
	Probe func(gh.Options, string) (gh.Visibility, error)
}

// Streamer runs one program with the caller's own stdin, stdout and stderr and no time bound, as the bash runs the
// final push: output appears as it is produced and a credential prompt can read the terminal. It returns the shell's
// exit status (127 when the program cannot start, 128+N for signal N).
type Streamer func(argv, env []string, in io.Reader, out, errw io.Writer) int

type deps struct {
	run     Runner
	stream  Streamer
	gh      GH
	hasTool func(name string, environ []string) bool // `command -v`
}

func realDeps() deps {
	return deps{run: procRun, stream: streamRun, gh: GH{Run: gh.Run, Probe: gh.Probe}, hasTool: onPath}
}

// The bash runs git and the scanner unbounded. Every run except the final `git push` is bounded here, long enough that no sane corpus hits it;
// a bound hit reads as exit 124, which every caller treats as a failure (fail closed).
const (
	shortBound = 10 * time.Minute
	longBound  = time.Hour
	maxOutput  = 256 << 20
)

// procRun is the production Runner: core/proc with the caller's environment.
func procRun(c Cmd) Out {
	res, err := proc.Run(proc.Spec{Argv: c.Argv, Env: c.Env, Timeout: c.Timeout, MaxBytes: maxOutput})
	if err != nil {
		return Out{RC: 127, Err: err}
	}
	return Out{RC: exitStatus(res), Stdout: res.Stdout, Stderr: res.Stderr}
}

// exitStatus maps a proc result to the status the shell would have seen. A run cut at the output cap never reads
// as success.
func exitStatus(res proc.Result) int {
	rc := res.ReturnCode
	switch {
	case res.Reason == proc.ReasonTimeout:
		return 124
	case rc < 0:
		return 128 - rc
	case res.Reason == proc.ReasonOutputCap && rc == 0:
		return 1
	}
	return rc
}

// onPath is `command -v name` against the PATH of environ (core/proc's default when it has none).
func onPath(name string, environ []string) bool {
	path := "/bin:/usr/bin"
	for _, kv := range environ {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = v
		}
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			dir = "."
		}
		if fi, err := os.Stat(filepath.Join(dir, name)); err == nil && fi.Mode().IsRegular() && fi.Mode()&0o111 != 0 {
			return true
		}
	}
	return false
}

// streamRun is the production Streamer. core/proc buffers and bounds every run, so the push goes through os/exec.
func streamRun(argv, env []string, in io.Reader, out, errw io.Writer) int {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = in, out, errw
	err := cmd.Run()
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return 127
	}
	if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ee.ExitCode()
}
