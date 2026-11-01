// Package stageissues is the Go port of toolbelt/stage-retro-issues.sh (`rsdd retro stage-issues`).
package stageissues

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Command is the registry entry of `rsdd retro stage-issues`.
var Command = cli.Command{
	Name:    "stage-issues",
	Group:   "retro",
	Summary: "propose (or with --apply create) GitHub issues for the open deltas of one retro",
	Run:     Run,
}

// Run is the command.
func Run(args []string, s cli.Stdio) int {
	fmt.Fprintln(s.Err, "stage-issues: not implemented")
	return cli.ExitOperational
}
