// Package verify owns the rsdd commands for verification instruments (verify block, registry, state, ...).
// See docs/adding-a-command.md.
package verify

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "kit-clean", Group: "verify", Summary: "is the kit repo clean, committed and pushed (port of verify-kit-clean.sh)", Run: RunKitClean},
	{Name: "block", Group: "verify", Summary: "mechanical self-verify of a Research-SDD block: marker tally, citation resolution, digests, ephemeral paths (port of verify-block.sh)", Run: RunBlock},
	{Name: "kit-clean-hook", Group: "verify", Summary: "SessionStart hook: emit the kit-clean report when the kit is not clean", Run: RunKitCleanHook},
}
