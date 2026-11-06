// Package runner starts the external tools of the sources domain (curl, wget, pandoc, pdftoppm, tesseract, file)
// and is the seam that lets every other package of the domain be tested without one: they take a Runner, the
// tests hand them a fake.
//
// Every real child leads its own process group, so cancelling the context signals the child AND whatever it
// started (a curl helper, a pandoc filter), the way the legacy script's `set -m` background job did.
package runner

import (
	"context"
	"errors"
	"io"
	"os/exec"
	"syscall"
)

// NotFound is the exit status of a program that cannot be started, as a shell reports it.
const NotFound = 127

// Runner runs one program to completion.
type Runner interface {
	// Run executes argv (argv[0] is looked up by the implementation), with stdin at /dev/null, stdout and stderr
	// to the given writers (nil discards). It returns the exit status; a child killed by signal N returns
	// 128+N, a program that cannot be started returns NotFound. When ctx is cancelled the child's process group
	// receives SIGTERM and Run returns once it has exited.
	Run(ctx context.Context, argv []string, stdout, stderr io.Writer) int
}

// Exec is the Runner that starts real processes.
type Exec struct {
	// Env is the child environment (KEY=VALUE); nil means the process environment.
	Env []string
	// Look resolves a program name to a path (the caller's PATH, not the process's).
	Look func(name string) (string, error)
}

// Run implements Runner.
func (e Exec) Run(ctx context.Context, argv []string, stdout, stderr io.Writer) int {
	if len(argv) == 0 {
		return NotFound
	}
	path, err := e.Look(argv[0])
	if err != nil {
		return NotFound
	}
	cmd := exec.Command(path, argv[1:]...)
	cmd.Env = e.Env
	cmd.Stdout, cmd.Stderr = stdout, stderr
	isolate(cmd)
	if err := cmd.Start(); err != nil {
		return NotFound
	}
	terminate := terminator(cmd)
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			terminate()
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	return status(cmd, err)
}

func status(cmd *exec.Cmd, err error) int {
	if err == nil {
		return 0
	}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return 1
}
