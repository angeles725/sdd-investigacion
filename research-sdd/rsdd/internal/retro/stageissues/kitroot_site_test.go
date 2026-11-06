package stageissues

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{"r.md": "# retro\n", "../../../nobin/git": "#!/bin/sh\nexit 1\n"}

var siteCmds = []kitsite.Cmd{
	{Name: "stage-issues", Run: Run, Args: func(k kitsite.Kit) []string { return []string{k.Root + "/r.md"} }, Script: "toolbelt/stage-retro-issues.sh", Files: []string{"r.md", "../../../nobin/git"}, Warn: true, RC: 1, Out: "kit-issue-repo: unresolved (no RESEARCH_SDD_ISSUE_REPO override and no resolvable git remote 'origin' at @P@)\n",
		Err: "target-paths: cannot read @K@/TARGETS.md\nstage-retro-issues: cannot resolve target for '@K@/r.md' — operational failure reading @K@/TARGETS.md (see message above)\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}
