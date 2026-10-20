// Package commands is the registry: one entry per `rsdd [<group>] <command>`.
// Adding a command = one file in its domain package + one line in Table.
package commands

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Table is the full command table consumed by cli.Run.
var Table = []cli.Command{
	versionCommand,
}

// Main is the Table-bound entry point (the golden kit's `main`).
func Main(args []string, s cli.Stdio) int { return cli.Run(Table, args, s) }
