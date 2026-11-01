// Package niagara owns the rsdd commands for Niagara tooling. The shared .bog reader every Niagara command
// builds on lives in the bog subpackage.
package niagara

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "bog-nav", Group: "niagara", Summary: "extract structural evidence from a Niagara config.bog", Run: RunBogNav},
}
