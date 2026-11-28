package goimpact_test

import (
	"strings"
	"testing"
)

func linesOf(t *testing.T, file string) []string {
	t.Helper()
	r := run("--repo", realRepo(t), file)
	if r.rc != 0 {
		t.Fatalf("go-impact %s: rc=%d %s", file, r.rc, r.err)
	}
	return r.lines()
}

func hasPrefixTab(lines []string, prefix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// A1: internal/commands/wire.go does `verify.SessionBudgetRunner = budget.RunSession`, so a change in
// internal/budget/session.go must reach the `verify registry` command (a SHIM line for it, or FULL), not only
// `budget session` plus whatever blind-spot file happens to run it.
func TestRealBudgetSessionReachesVerifyRegistry(t *testing.T) {
	lines := linesOf(t, "research-sdd/rsdd/internal/budget/session.go")
	if !hasPrefixTab(lines, "FULL\t") && !hasSuffixed(lines, "SHIM\t", "\tverify registry") {
		t.Errorf("budget/session.go reaches neither FULL nor a `verify registry` SHIM:\n%s", strings.Join(lines, "\n"))
	}
}

func hasSuffixed(lines []string, prefix, suffix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) && strings.HasSuffix(l, suffix) {
			return true
		}
	}
	return false
}

// A2: internal/gate embeds testdata/mergetrain/help.txt with //go:embed; the file selects kit-merge-train's shim
// or FULL, never go-test-only.
func TestRealEmbeddedMergeTrainHelpIsNotTestOnly(t *testing.T) {
	lines := linesOf(t, "research-sdd/rsdd/internal/gate/testdata/mergetrain/help.txt")
	if !hasPrefixTab(lines, "FULL\t") && !hasSuffixed(lines, "SHIM\t", "kit-merge-train.sh\tgate merge-train") {
		t.Errorf("embedded help.txt is neither FULL nor kit-merge-train's SHIM:\n%s", strings.Join(lines, "\n"))
	}
	for _, l := range lines {
		if strings.HasSuffix(l, "go-test-only") {
			t.Errorf("embedded help.txt is go-test-only: %s", l)
		}
	}
}

// A3: Go -> bash -> Go is not an edge this tool reads: `sweep all` (internal/sweep) runs toolbelt scripts such
// as verify-registry.sh, which call back into internal/verify. A change in internal/verify must therefore answer
// FULL here (the closure is wider than --wide), never a quiet narrow selection that omits the sweep suites.
// Issue #2770 PR (b) replaces those bash calls with a core helper whose call sites pass the group and the name
// as literal arguments; that literal call form is the edge go-impact will read. Until it lands, FULL is the pin.
func TestRealVerifyChangeIsFullNotNarrow(t *testing.T) {
	lines := linesOf(t, "research-sdd/rsdd/internal/verify/registry.go")
	if !hasPrefixTab(lines, "FULL\t") {
		t.Errorf("internal/verify/registry.go must answer FULL (Go -> bash -> Go is unread):\n%s", strings.Join(lines, "\n"))
	}
}
