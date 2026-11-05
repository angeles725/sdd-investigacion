package secretscan

import (
	"io"
	"os/exec"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// Git is the seam through which --committed reaches the version-control tool, the scanner's only runtime
// dependency (the legacy script also needed awk, tr, grep and mktemp; the engine needs none of them). A test
// injects a fake to reproduce enumeration and object-read failures; the default runs the real tool.
type Git interface {
	// Start runs `git -C dir args...` with stdin and returns its output stream. An error means it could not run.
	Start(dir string, stdin io.Reader, args ...string) (Proc, error)
}

// Proc is a started Git command: read Stdout to the end, then Wait.
type Proc interface {
	Stdout() io.Reader
	// Wait returns the exit code (127 when the program could not run); stderr is discarded (`2>/dev/null`).
	Wait() int
}

// execGit runs the real tool found on the request's PATH.
type execGit struct {
	path string
	env  []string
}

// newExecGit resolves git on the PATH of env; ok is false when it is not there (a typed degraded state).
func newExecGit(env []string, cwd string) (Git, bool) {
	p, err := probe.New(env, cwd).LookPath("git")
	if err != nil {
		return nil, false
	}
	return execGit{path: p, env: env}, true
}

type execProc struct {
	cmd *exec.Cmd
	out io.Reader
}

func (g execGit) Start(dir string, stdin io.Reader, args ...string) (Proc, error) {
	cmd := exec.Command(g.path, append([]string{"-C", dir}, args...)...)
	cmd.Env, cmd.Stdin = g.env, stdin
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &execProc{cmd: cmd, out: out}, nil
}

func (p *execProc) Stdout() io.Reader { return p.out }

func (p *execProc) Wait() int {
	if err := p.cmd.Wait(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return 127
	}
	return 0
}

// gitText runs a short command and returns its whole stdout and exit code.
func gitText(g Git, dir string, args ...string) (string, int) {
	p, err := g.Start(dir, nil, args...)
	if err != nil {
		return "", 127
	}
	b, _ := io.ReadAll(p.Stdout())
	return string(b), p.Wait()
}

// firstLine is `$(cmd)` for a one-line answer: the output up to the first newline, trailing newlines cut.
func firstLine(s string) string { return strings.TrimRight(s, "\n") }
