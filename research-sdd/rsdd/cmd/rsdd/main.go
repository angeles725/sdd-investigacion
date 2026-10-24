// Command rsdd is the Go port of the research-sdd toolbelt.
package main

import (
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func main() {
	// The rlimit re-exec helper is internal: dispatched before the command
	// table, so it never appears in usage and never buffers the program's output.
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	os.Exit(cli.RunProcess(commands.Table, os.Args[1:]))
}
