// Package gate owns the rsdd commands for gates (retro, return-token, merge, secrets, vendor-leak, clean).
// A porting unit adds its entries to Commands; see docs/adding-a-command.md.
package gate

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "return-token", Group: "gate", Summary: "Stop hook: block once when the final report's continuation token is missing or wrong", Run: RunReturnToken},
}
