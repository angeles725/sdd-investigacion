// Command rsdd is the Go port of the research-sdd toolbelt.
package main

import (
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands"
)

func main() { os.Exit(cli.Run(commands.Table, os.Args[1:], cli.OSStdio())) }
