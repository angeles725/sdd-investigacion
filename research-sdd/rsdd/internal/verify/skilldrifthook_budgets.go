package verify

import "time"

// hookBudgets are the time budgets of the skill-drift hook. The command runs on defaultHookBudgets; a test
// injects short ones so it does not sleep on production values. This is the only place the defaults live.
type hookBudgets struct {
	// verifyUnit is what one unit of RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT means (the env value is whole seconds).
	verifyUnit time.Duration
	// verifyDefault is the install --verify bound, in verifyUnits, when the env value is unset or invalid.
	verifyDefault int
	// kitStale is the one budget the kit-staleness git calls share.
	kitStale time.Duration
}

func defaultHookBudgets() hookBudgets {
	return hookBudgets{verifyUnit: time.Second, verifyDefault: 10, kitStale: 3 * time.Second}
}

// verifyBound is the install --verify bound for an env value of n units.
func (b hookBudgets) verifyBound(n int) time.Duration { return time.Duration(n) * b.verifyUnit }
