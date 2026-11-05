// Package maint owns the rsdd commands for kit-only maintenance tooling.
// See docs/adding-a-command.md.
package maint

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/gate"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "rdd-start", Group: "maint", Summary: "assess the committed range and start the native review (explicit consent)", Run: RddStart},
	{Name: "gate", Group: "maint", Summary: "run ONE serial full gate under a flock, log it and echo its summary (kit-gate)", Run: gate.Run},
	{Name: "rdd-drive", Group: "maint", Summary: "follow the provider-issued review transitions to acknowledgement", Run: RddDrive},
}
