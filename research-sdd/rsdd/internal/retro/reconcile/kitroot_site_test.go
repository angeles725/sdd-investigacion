package reconcile

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{}

var siteCmds = []kitsite.Cmd{
	{Name: "reconcile", Run: RunCommand, Args: func(k kitsite.Kit) []string {
		return []string{"--all", "--issues-cache", k.Home + "/i.json", "--closed-cache", k.Home + "/c.json"}
	}, Script: "toolbelt/reconcile-issues.sh", Warn: true, RC: 1, Err: "absent-input: TARGETS.md not found: @K@/TARGETS.md\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}
