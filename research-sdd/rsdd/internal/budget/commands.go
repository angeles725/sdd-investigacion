// Package budget owns the rsdd commands for session-context budget measurement.
package budget

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "verify", Group: "budget", Summary: "Measure what a target's SessionStart hooks (or pi extensions) hand to the model, in decoded characters", Run: Run},
}
