package sweep

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// The five sweep commands find the kit without --kit through one resolution that names no script (#2770); the
// scenarios and the harness are in internal/testkit/kitsite.

var siteBodies = map[string]string{"TARGETS.md": "# targets\n"}

// allFiles are the eight scripts `sweep all` runs (empty files: each passes).
var allFiles = func() []string {
	var l []string
	for _, n := range allScripts {
		l = append(l, "toolbelt/"+n)
	}
	return l
}()

// allOut is the report of eight passing scripts.
func allOut() string {
	bar := strings.Repeat("=", 40) + "\n"
	var b, sum strings.Builder
	for _, n := range allScripts {
		b.WriteString("\n" + bar + "== " + n + "\n" + bar + "\nPASS  " + n + "\n")
		sum.WriteString("  PASS  " + n + "\n")
	}
	return b.String() + "\n" + bar + "== sweep-all summary\n" + bar + sum.String()
}

var siteCmds = []kitsite.Cmd{
	{Name: "all", Run: RunAll, Script: "toolbelt/sweep-all.sh", Files: append([]string{"TARGETS.md"}, allFiles...), Warn: true, Out: allOut()},
	{Name: "retros", Run: RunRetros, Script: "toolbelt/sweep-retros.sh", Files: []string{"TARGETS.md"}, Warn: true, RC: 1,
		Err: "sweep-retros: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-retros: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{Name: "audits", Run: RunAudits, Script: "toolbelt/sweep-audits.sh", Files: []string{"TARGETS.md"}, Warn: true, RC: 1,
		Err: "sweep-audits: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-audits: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{Name: "breakthroughs", Run: RunBreakthroughs, Script: "toolbelt/sweep-breakthroughs.sh", Files: []string{"TARGETS.md"}, Warn: true, RC: 1,
		Err: "sweep-breakthroughs: cannot find @K@/BREAKTHROUGHS.md\n"},
	{Name: "tools", Run: RunTools, Script: "toolbelt/sweep-tools.sh", Files: []string{"TARGETS.md"}, Warn: true, RC: 1,
		Err: "sweep-tools: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-tools: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
}

func TestSweepKitFound(t *testing.T) {
	kitsite.RunSuite(t, kitsite.Suite{Profile: kitsite.SystemPath, Bodies: siteBodies, Cmds: siteCmds})
}

// A hook run hands its diagnostics to the model as context and a --json run promises one JSON document on stdout:
// an invalid RESEARCH_SDD_KIT changes neither stdout nor the exit code, and the warning is on the process's stderr
// in both modes, never in the hook's context.
func TestSweepKitWarningStaysOutOfStdout(t *testing.T) {
	suite := kitsite.Suite{Profile: kitsite.SystemPath, Bodies: siteBodies, Cmds: siteCmds}
	for _, c := range siteCmds[1:] { // sweep all has no hook or --json mode
		for _, mode := range []string{"--hook", "--json"} {
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
				warn := kitsite.InvalidKitWarning(bare)
				if mode == "--json" {
					warn += wantErr
				} else if wantErr != "" {
					t.Fatalf("the hook baseline wrote stderr: %q", wantErr)
				}
				if errOut != warn {
					t.Fatalf("stderr %q, want %q", errOut, warn)
				}
			})
		}
	}
}
