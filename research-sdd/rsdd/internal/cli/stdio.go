// Package cli is the process boundary of rsdd: it owns argument dispatch,
// usage/help rendering, exit-code mapping and the panic boundary. Nothing
// below this package reads the environment, the clock or the working
// directory directly; everything arrives through Stdio.
package cli

import (
	"fmt"
	"io"
	"os"
	"time"
)

// Stdio carries every ambient dependency a command may use.
type Stdio struct {
	In  io.Reader
	Out io.Writer
	Err io.Writer
	Env func(key string) string
	// Environ returns the whole environment as KEY=VALUE pairs (os.Environ's form), for a command that
	// hands a child process the caller's environment.
	Environ func() []string
	Clock   func() time.Time
	Cwd     string
}

// Environment is Environ(), or nil when no Environ was given (a test Stdio). A nil environment handed to
// exec.Cmd means the process environment, so a caller that must not leak it checks for nil itself.
func (s Stdio) Environment() []string {
	if s.Environ == nil {
		return nil
	}
	return s.Environ()
}

// OSStdio builds the real Stdio. It is the only place that touches
// os.Stdin/Stdout/Stderr, os.Getenv, os.Environ, time.Now and os.Getwd. A working
// directory that cannot be determined is an error, never an empty Cwd.
func OSStdio() (Stdio, error) { return osStdio(os.Getwd) }

func osStdio(getwd func() (string, error)) (Stdio, error) {
	cwd, err := getwd()
	if err != nil {
		return Stdio{}, fmt.Errorf("cannot determine working directory: %w", err)
	}
	return Stdio{
		In:      os.Stdin,
		Out:     os.Stdout,
		Err:     os.Stderr,
		Env:     os.Getenv,
		Environ: os.Environ,
		Clock:   time.Now,
		Cwd:     cwd,
	}, nil
}

// Environ is the process environment for the one caller that runs before a Stdio exists: main's
// dispatch of the rlimit re-exec helper. Commands use Stdio.Environ.
func Environ() []string { return os.Environ() }

// RunProcess is what main calls: build the real Stdio, then dispatch.
func RunProcess(table []Command, args []string) int {
	return runProcess(table, args, os.Getwd, os.Stderr)
}

func runProcess(table []Command, args []string, getwd func() (string, error), errw io.Writer) int {
	s, err := osStdio(getwd)
	if err != nil {
		fmt.Fprintf(errw, "rsdd: %v\n", err)
		return ExitOperational
	}
	return Run(table, args, s)
}
