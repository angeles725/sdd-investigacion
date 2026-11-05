package sweep

import (
	"bytes"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// TestUnknownArgumentIsAUsageError pins #2687: the shared parser of retros, audits, tools and breakthroughs refuses
// an argument it does not know before any output. Intended divergence: the scripts ignored such an argument and
// answered in a mode the caller did not ask for (these were the "unknown arguments are ignored" scenario rows).
func TestUnknownArgumentIsAUsageError(t *testing.T) {
	w := newWorld(t)
	for _, name := range []string{"retros", "audits", "tools", "breakthroughs"} {
		for _, args := range [][]string{
			{"--jsno"},
			{"--kit", w.kit, "stray"},
		} {
			var o, e bytes.Buffer
			bad := args[len(args)-1]
			if args[0] == "--jsno" {
				bad = "--jsno"
			}
			want := "sweep-" + name + ": unsupported argument \"" + bad + "\"\n"
			rc := cli.Run(Commands, append([]string{"sweep", name}, args...), w.stdio(&o, &e))
			if rc != cli.ExitUsage || o.Len() != 0 || e.String() != want {
				t.Errorf("sweep %s %q: rc=%d stdout=%q stderr=%q, want rc=%d and %q", name, args, rc, o.String(), e.String(), cli.ExitUsage, want)
			}
		}
	}
}

// In hook mode the hook contract holds (exit 0, nothing on stderr): the same line is reported in the hook's own
// "could not run" context with the usage exit code, whether --hook comes before or after the bad argument.
func TestUnknownArgumentInHookModeKeepsTheHookContract(t *testing.T) {
	w := newWorld(t)
	heads := map[string]string{"retros": "retro", "audits": "audits", "tools": "tools", "breakthroughs": "breakthroughs"}
	for name, head := range heads {
		for _, args := range [][]string{{"--hook", "--kit", w.kit, "--json", "--all"}, {"--all", "--hook"}} {
			var o, e bytes.Buffer
			rc := cli.Run(Commands, append([]string{"sweep", name}, args...), w.stdio(&o, &e))
			want := "Research-SDD " + head + " sweep could not run (exit 2 — check TARGETS.md and lib/ helper):\nsweep-" + name + ": unsupported argument \"--all\""
			if rc != cli.ExitOK || e.Len() != 0 || decodeHookCtx(t, o.String()) != want {
				t.Errorf("sweep %s %q: rc=%d stderr=%q stdout=%q, want rc 0 and context %q", name, args, rc, e.String(), o.String(), want)
			}
		}
	}
}

// The first problem in argument order is the one reported: an unknown argument before a dangling --kit.
func TestFirstArgumentProblemWins(t *testing.T) {
	w := newWorld(t)
	var o, e bytes.Buffer
	if rc := cli.Run(Commands, []string{"sweep", "retros", "x", "--kit"}, w.stdio(&o, &e)); rc != cli.ExitUsage || e.String() != "sweep-retros: unsupported argument \"x\"\n" {
		t.Errorf("rc=%d stderr=%q", rc, e.String())
	}
	o.Reset()
	e.Reset()
	if rc := cli.Run(Commands, []string{"sweep", "retros", "--kit"}, w.stdio(&o, &e)); rc != cli.ExitUsage || e.String() != "sweep-retros: --kit needs a directory\n" {
		t.Errorf("rc=%d stderr=%q", rc, e.String())
	}
}
