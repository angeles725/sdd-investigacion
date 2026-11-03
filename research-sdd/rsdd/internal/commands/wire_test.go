package commands

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/verify"
)

// Without the seam `verify registry` would count its session-budget check as skipped on every run.
func TestSessionBudgetRunnerIsWired(t *testing.T) {
	if verify.SessionBudgetRunner == nil {
		t.Fatal("verify.SessionBudgetRunner is not set by the composition tier")
	}
}
