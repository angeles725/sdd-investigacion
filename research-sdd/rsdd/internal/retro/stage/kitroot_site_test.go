package stage

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{"r.md": "# retro\n", "../../../nobin/git": "#!/bin/sh\nexit 1\n"}

var siteCmds = []kitsite.Cmd{
	{Name: "stage", Run: RunCommand, Args: func(k kitsite.Kit) []string { return []string{k.Root + "/r.md"} }, Script: "toolbelt/stage-retro.sh", Files: []string{"r.md", "../../../nobin/git"}, Warn: true, RC: 4, Err: "target-paths: cannot read @K@/TARGETS.md\nWARN: target-name lookup FAILED (rc=1, operational — the registry could not be consulted, see the message above) for '@K@/r.md' — labelling with directory basename 'sdd-investigacion', which may differ from the registered target name\ndegraded: git could not read the state of the kit repo in @P@ (git status --porcelain: exit 1) — nothing was changed.\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}
