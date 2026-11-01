package skilldrift

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this package's contribution to the verify domain's table (internal/verify/commands.go adds it with one line).
var Commands = []cli.Command{
	{Name: "skill-drift", Group: "verify", Summary: "is a deployed SKILL.md the kit's source (port of verify-skill-drift.sh)", Run: RunDrift},
	{Name: "skill-drift-hook", Group: "verify", Summary: "SessionStart hook: skill drift, install --verify findings, stale kit", Run: RunHook},
}
