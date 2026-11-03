// Package verify owns the rsdd commands for verification instruments (verify block, registry, state, ...).
// See docs/adding-a-command.md.
package verify

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/verify/corrections"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "kit-clean", Group: "verify", Summary: "is the kit repo clean, committed and pushed (port of verify-kit-clean.sh)", Run: RunKitClean},
	{Name: "state", Group: "verify", Summary: "RESEARCH-STATE living-mirror consistency lint (port of verify-state.sh)", Run: RunState, ExitMap: map[int]int{Stale: 1}},
	{Name: "kit-clean-hook", Group: "verify", Summary: "SessionStart hook: emit the kit-clean report when the kit is not clean", Run: RunKitCleanHook},
	{Name: "registry", Group: "verify", Summary: "reconcile TARGETS.md against the corpora on disk (port of verify-registry.sh)", Run: RunRegistry},
	{Name: "registry-hook", Group: "verify", Summary: "SessionStart hook: emit the compact registry check (--full for the whole report)", Run: RunRegistryHook},
	{Name: "corrections", Group: "verify", Summary: "section-14 reciprocal-backlink lint of a corpus (port of verify-corrections.sh)", Run: corrections.Run},
	{Name: "skill-drift", Group: "verify", Summary: "is a deployed SKILL.md the kit's source (port of verify-skill-drift.sh; --hook is the SessionStart hook)", Run: RunSkillDrift},
}
