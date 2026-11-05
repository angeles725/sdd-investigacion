package gate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitgate"
)

// kitGate is toolbelt/maint/kit-gate.sh <worktree> <label>, in process (core/kitgate, shared with `rsdd maint gate`):
// ONE serial gate under a flock on <state>/gate.lock, its output in <state>/gate-<label>.log, the summary lines
// echoed. It returns the typed exit code of the bash tool (0 passed, 2 usage, 16 gate-failed, 22 gate-lock-timeout)
// and the gate command's own rc.
func (g *train) kitGate(label string) (code, gateRC int) {
	res := kitgate.Run(kitgate.Opts{
		Out: g.s.Out, R: g.kr, Wt: g.wt, Label: label, State: g.state,
		Cmd: g.gateCmd, Serial: g.serial, LockTimeout: g.s.Env("KIT_GATE_LOCK_TIMEOUT"), Sig: g.sig,
		SilentNoBash: true, OverflowTriesOnce: true, // what the train printed and waited before the extraction
	})
	if res.Interrupted {
		g.interrupted = true // the signal killed kit-gate.sh with its gate in the bash: no `gate rc=` line, no summary
	}
	return res.Code, res.GateRC
}
