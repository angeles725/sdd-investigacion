// Package verify owns the rsdd commands for verification instruments (verify block, registry, state, ...).
// See docs/adding-a-command.md.
package verify

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "kit-clean", Group: "verify", Summary: "is the kit repo clean, committed and pushed (port of verify-kit-clean.sh)", Run: RunKitClean},
	{Name: "kit-clean-hook", Group: "verify", Summary: "SessionStart hook: emit the kit-clean report when the kit is not clean", Run: RunKitCleanHook},
	{Name: "registry", Group: "verify", Summary: "reconcile TARGETS.md against the corpora on disk (port of verify-registry.sh; INCOMPLETE: hook-wiring checks pending, U2.7c)", Run: RunRegistry},
	{Name: "skill-drift", Group: "verify", Summary: "is a deployed SKILL.md the kit's source (port of verify-skill-drift.sh; --hook is the SessionStart hook)", Run: RunSkillDrift},
}
