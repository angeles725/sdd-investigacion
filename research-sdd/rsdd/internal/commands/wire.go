package commands

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/budget"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/verify"
)

// Seams between domains. A domain cannot import another (archtest), so a command that needs a sibling
// domain's command takes it as a variable and this tier, the only one allowed to import domains, fills it.
func init() {
	// `verify registry` measures a target's SessionStart hooks with `budget session` (verify-registry.sh ran
	// verify-session-budget.sh for the same check, kit issue #2129).
	verify.SessionBudgetRunner = budget.RunSession
}
