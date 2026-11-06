package verify

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"

// The command each verify SessionStart hook names in a capped could-not-run context: its own non-hook command, whose
// output is the whole of what the hook cut (kit issue #2631). TestVerifyHookRerunCommandsExist checks each against
// Commands.
const (
	registryRerun   = "rsdd verify registry"
	kitCleanRerun   = "rsdd verify kit-clean"
	skillDriftRerun = "rsdd verify skill-drift"
)

// capIf is the additionalContext of header and out: capped by hookenv.FailureContext when the check could not run,
// else exactly header, a newline and out (a finding is reported whole).
func capIf(couldNotRun bool, header, out, rerun string) string {
	if couldNotRun {
		return hookenv.FailureContext(header, out, rerun)
	}
	return header + "\n" + out
}
