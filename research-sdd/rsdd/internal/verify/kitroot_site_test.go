package verify

import (
	"encoding/json"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The commands below find the kit without a flag through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{"TARGETS.md": "# targets\n"}

var siteCmds = []kitsite.Cmd{
	{Name: "registry", Run: RunRegistry, Script: "toolbelt/verify-registry.sh", Files: []string{"TARGETS.md"}, Warn: true, RC: 0, Err: "verify-registry: ERROR — no usable target paths in @K@/TARGETS.md\nverify-registry: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{Name: "skill-drift", Run: RunSkillDrift, Script: "toolbelt/verify-skill-drift.sh", Files: []string{"install/keep"}, Warn: true, RC: 2, Err: "verify-skill-drift: ERROR: adapters.sh not found: @K@/install/adapters.sh\n"},
}

func TestKitFoundWithoutAFlag(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds})
}

// An invalid RESEARCH_SDD_KIT changes neither the stdout nor the exit code of a --json or --hook run; the line is on
// stderr (the hook of skill-drift writes its own stderr apart from the context it hands the model).
func TestKitWarningStaysOutOfStdout(t *testing.T) {
	suite := kitsite.Suite{Profile: kitsite.NoPath, Bodies: siteBodies, Cmds: siteCmds}
	for _, c := range siteCmds {
		mode := map[string]string{"registry": "--json", "skill-drift": "--hook"}[c.Name]
		t.Run(c.Name+" "+mode, func(t *testing.T) {
			k := suite.Kit(t, c, true)
			bare := k.Bare(t)
			wantOut, wantErr, wantRC := k.Run(c.Run, []string{mode}, "", k.Home)
			out, errOut, rc := k.Run(c.Run, []string{mode}, bare, k.Home)
			if out != wantOut || rc != wantRC {
				t.Fatalf("rc=%d stdout %q, want rc=%d stdout %q", rc, out, wantRC, wantOut)
			}
			if out != "" && !json.Valid([]byte(out)) {
				t.Fatalf("stdout is not one JSON document: %q", out)
			}
			if want := kitsite.InvalidKitWarning(bare) + wantErr; errOut != want {
				t.Fatalf("stderr %q, want %q", errOut, want)
			}
		})
	}
}
