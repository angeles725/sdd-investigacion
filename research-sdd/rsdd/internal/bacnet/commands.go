// Package bacnet owns the rsdd commands for BACnet tooling.
// See docs/adding-a-command.md.
package bacnet

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "corroborate-bacnet", Group: "bacnet", Summary: "read-only BACnet/IP reachability and BBMD evidence probe (bacnet-evidence.v1)", Run: CorroborateBACnet},
}
