//go:build !nodiff && unix

package verify

import (
	"fmt"
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The production hooks against the frozen script: the same scenarios as TestRegistryDifferential, but the Go side
// keeps the PRODUCTION newRegistryHooks (core/hookwiring in process) instead of the bash-backed shellHooks, so the
// real implementation, not a stand-in, is what is compared with the legacy lib/hook-wiring.sh. The session-budget
// runner is a Go twin of the budgetStub the legacy kit carries (the real meter has its own differential in
// internal/budget).
func stubBudgetRunner(args []string, s cli.Stdio) int {
	switch filepath.Base(args[len(args)-1]) {
	case "over":
		fmt.Fprint(s.Out, "hook a status=TRUNCATED\nhook b status=timed-out\naggregate: 9123 chars worst-source=startup\nOVER BUDGET\nstate: degraded\n")
	case "nostate":
		fmt.Fprintln(s.Out, "crashed")
	default:
		fmt.Fprintln(s.Out, "state: ok")
	}
	return cli.ExitOK
}

func (k *vrKit) runBothProduction(name string, env map[string]string, args ...string) {
	k.t.Helper()
	legacyRes := k.runLegacy(env, args...)
	old := SessionBudgetRunner
	SessionBudgetRunner = stubBudgetRunner
	defer func() { SessionBudgetRunner = old }()
	goRes := k.run(env, args...)
	if legacyRes != goRes {
		k.t.Errorf("%s %v (production hooks) differs from the legacy script:\nlegacy rc=%d\n--stdout--\n%s--stderr--\n%s\n    go rc=%d\n--stdout--\n%s--stderr--\n%s",
			name, args, legacyRes.rc, legacyRes.stdout, legacyRes.stderr, goRes.rc, goRes.stdout, goRes.stderr)
	}
}

func TestRegistryProductionDifferential(t *testing.T) {
	for _, sc := range registryScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			k := newVRKit(t)
			k.installLegacy()
			env := sc.build(k)
			k.runBothProduction(sc.name, env)
			k.runBothProduction(sc.name, env, "--json")
		})
	}
}
