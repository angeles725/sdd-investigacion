// Package cli is the process boundary of rsdd: it owns argument dispatch,
// usage/help rendering, exit-code mapping and the panic boundary. Nothing
// below this package reads the environment, the clock or the working
// directory directly; everything arrives through Stdio.
package cli

import (
	"io"
	"os"
	"time"
)

// Stdio carries every ambient dependency a command may use.
type Stdio struct {
	In    io.Reader
	Out   io.Writer
	Err   io.Writer
	Env   func(key string) string
	Clock func() time.Time
	Cwd   string
}

// OSStdio builds the real Stdio. It is the only place that touches
// os.Stdin/Stdout/Stderr, os.Getenv, time.Now and os.Getwd.
func OSStdio() Stdio {
	cwd, _ := os.Getwd()
	return Stdio{
		In:    os.Stdin,
		Out:   os.Stdout,
		Err:   os.Stderr,
		Env:   os.Getenv,
		Clock: time.Now,
		Cwd:   cwd,
	}
}
