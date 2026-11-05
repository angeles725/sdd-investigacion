// Package flakehunt is `rsdd maint flake-hunt`, the port of toolbelt/maint/kit-flake-hunt.sh (stub: the tests come first).
package flakehunt

import (
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// deps is what the command takes from outside; tests replace the signal source.
type deps struct {
	notify func() (<-chan os.Signal, func())
}

type options struct{}

// stop is a run that ends early: the exit code and the stderr text.
type stop struct {
	code int
	msg  string
}

func parse(args []string) (options, *stop) { return options{}, nil }

// Run is `rsdd maint flake-hunt`.
func Run(args []string, s cli.Stdio) int { return run(args, s, deps{}) }

func run(args []string, s cli.Stdio, d deps) int { return 99 }
