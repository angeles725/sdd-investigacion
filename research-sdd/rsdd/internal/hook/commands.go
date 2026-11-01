// Package hook owns the rsdd commands for session-start sweeps and the kit-run hook entry points.
// See docs/adding-a-command.md.
package hook

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "emit", Group: "hook", Summary: "print a SessionStart additionalContext envelope (port of hook-emit.sh)", Run: Emit},
}
