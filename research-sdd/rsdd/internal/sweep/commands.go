// Package sweep owns the rsdd commands for corpus sweeps (retros, audits, registry).
// See docs/adding-a-command.md.
package sweep

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "retros", Group: "sweep", Summary: "pending section 18 retros of every target in TARGETS.md (port of sweep-retros.sh; --hook is the SessionStart hook)", Run: RunRetros},
	{Name: "audits", Group: "sweep", Summary: "pending section 13 audits of every target in TARGETS.md (port of sweep-audits.sh; --hook is the SessionStart hook)", Run: RunAudits},
	{Name: "breakthroughs", Group: "sweep", Summary: "unindexed and drifted section 22 breakthroughs of every target in TARGETS.md (port of sweep-breakthroughs.sh; --hook is the SessionStart hook)", Run: RunBreakthroughs},
	{Name: "tools", Group: "sweep", Summary: "tool census and ledger reconciliation of every target in TARGETS.md (port of sweep-tools.sh; --hook is the SessionStart hook)", Run: RunTools},
}
