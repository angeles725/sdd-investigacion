package fidelity

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{}

var siteCmds = []kitsite.Cmd{
	{Name: "java-fidelity", Run: Run, Script: "toolbelt/decompile-java.sh", RelAsWritten: true, RC: 2, Err: "fixtures directory not found: @T@/tests/fixtures/java-fidelity-experiment\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}
