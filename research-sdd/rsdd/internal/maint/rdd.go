package maint

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Typed exit states shared by rdd-start and rdd-drive (kit issue #2212; the legacy kit-rdd-*.py contract,
// pinned by tests/kit-rdd-start.test.sh and tests/kit-rdd-drive.test.sh).
const (
	rddOK         = 0
	rddUsage      = cli.ExitUsage
	rddDegraded   = cli.ExitDegraded
	rddNotDue     = 10
	rddNotApprove = 13
	rddError      = 14 // rdd-start-error (start) and rdd-protocol-error (drive)
	rddConsent    = 15
)

const (
	// A provider command has no bound in the legacy tools; a reviewer capture is a model run. The bound
	// is a backstop against a hung provider, not an expected limit.
	toolTimeout  = 6 * time.Hour
	toolMaxBytes = 256 << 20
)

// ambientEnviron is the process environment handed to every provider command. The legacy tools let
// gentle-ai inherit the whole environment, and cli.Stdio can only look a key up, never list them, so this one
// read of os.Environ is a deliberate, flagged exception to the Stdio rule (the archtest bans only Getenv,
// LookupEnv, Getwd and time.Now). Unit tests never reach it: they inject a fake tool.
var ambientEnviron = os.Environ

const defaultPath = "/bin:/usr/bin"

// result is what one provider command produced.
type result struct {
	stdout, stderr string
	rc             int
}

// tool is the seam to the gentle-ai binary: production runs it under core/proc, tests inject a fake.
type tool interface {
	// present reports whether gentle-ai can be found (shutil.which in the legacy tool).
	present() error
	// run executes argv in dir and returns once it has exited; a command that cannot run is an error.
	run(argv []string, dir string) (result, error)
}

type osTool struct {
	path string
	env  []string
	cwd  string
}

func newOSTool(s cli.Stdio) osTool {
	path := s.Env("PATH")
	if path == "" {
		path = defaultPath
	}
	env := []string{"PATH=" + path}
	for _, kv := range ambientEnviron() {
		if !strings.HasPrefix(kv, "PATH=") {
			env = append(env, kv)
		}
	}
	return osTool{path: path, env: env, cwd: s.Cwd}
}

func (t osTool) present() error {
	_, err := probe.New([]string{"PATH=" + t.path}, t.cwd).LookPath("gentle-ai")
	return err
}

func (t osTool) run(argv []string, dir string) (result, error) {
	res, err := proc.Run(proc.Spec{Argv: argv, Dir: dir, Env: t.env, Timeout: toolTimeout, MaxBytes: toolMaxBytes})
	if err != nil {
		return result{}, err
	}
	if res.Reason != "" {
		return result{}, fmt.Errorf("%s stopped: %s", strings.Join(argv[:min(len(argv), 4)], " "), res.Reason)
	}
	return result{stdout: string(res.Stdout), stderr: string(res.Stderr), rc: res.ReturnCode}, nil
}

// exit is an early return carrying the process exit code; the text was already printed.
type exit struct{ code int }

func (e *exit) Error() string { return fmt.Sprintf("exit %d", e.code) }

// finish maps a driver's error to the exit code: an *exit carries its own, anything else is operational.
func finish(err error, s cli.Stdio, who string) int {
	if err == nil {
		return rddOK
	}
	var e *exit
	if errors.As(err, &e) {
		return e.code
	}
	fmt.Fprintf(s.Err, "rsdd: maint %s: %v\n", who, err)
	return cli.ExitOperational
}

// degraded prints the legacy stdout line and the typed stderr line, and returns exit 3.
func degraded(out, errw io.Writer, legacy string) int {
	fmt.Fprintln(out, legacy)
	fmt.Fprintln(errw, "DEGRADED: missing runtime dependency: gentle-ai")
	return rddDegraded
}

// usageFail prints argparse's two lines and returns exit 2.
func usageFail(errw io.Writer, usage, prog string, err error) int {
	fmt.Fprintln(errw, usage)
	fmt.Fprintf(errw, "%s: error: %v\n", prog, err)
	return rddUsage
}

func readFile(path string) ([]byte, error) { return os.ReadFile(path) }
