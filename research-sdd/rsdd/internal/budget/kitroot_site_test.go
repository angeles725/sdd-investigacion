package budget

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{}

var siteCmds = []kitsite.Cmd{
	{Name: "session", Run: RunSession, Args: func(k kitsite.Kit) []string { return []string{"--harness", "pi", k.Home} }, Script: "toolbelt/lib/session-budget-pi.mjs", RelAsWritten: true, Warn: true, RC: 0, Out: "verify-session-budget: @H@\nharness: pi (kit extension research-sdd-hooks.ts + <target>/.pi/extensions/*; sections added on before_agent_start after a startup session_start)\nlimits: fake pi (no-op API, no ctx.mode/model/tools); session_start handlers run in parallel, before_agent_start one after another; counted: sections, returned message content; unmeasured (typed): returned systemPrompt, event.systemPrompt edits\nkit: @K@\npi: DEGRADED — node unavailable\nstate: degraded (node unavailable; nothing was measured on pi)\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}
