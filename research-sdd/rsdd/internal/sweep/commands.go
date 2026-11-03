// Package sweep owns the rsdd commands for corpus sweeps (retros, audits, registry).
// See docs/adding-a-command.md.
package sweep

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "retros", Group: "sweep", Summary: "pending section 18 retros of every target in TARGETS.md (port of sweep-retros.sh; --hook is the SessionStart hook)", Run: RunRetros},
}
