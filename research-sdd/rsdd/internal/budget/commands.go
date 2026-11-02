// Package budget owns the rsdd commands for session-context budget measurement (see session.go).
// See docs/adding-a-command.md.
package budget

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "session", Group: "budget", Summary: "measure what SessionStart hooks / pi extensions hand to the model (port of verify-session-budget.sh)", Run: RunSession},
}
