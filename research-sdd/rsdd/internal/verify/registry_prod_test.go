package verify

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The production registryHooks (productionHooks): lib/hook-wiring.sh's checks run in process through
// internal/core/hookwiring, and verify-session-budget.sh through SessionBudgetRunner, set by the composition tier.

func withBudgetRunner(t *testing.T, f func(args []string, s cli.Stdio) int) {
	t.Helper()
	old := SessionBudgetRunner
	SessionBudgetRunner = f
	t.Cleanup(func() { SessionBudgetRunner = old })
}

func TestRegistryProductionHooksRunWithoutSkipping(t *testing.T) {
	t.Parallel()
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.put("alpha/.claude/settings.json", "{}\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / hook yes)")))
	r := k.run(map[string]string{"RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")})
	rcIs(t, r, 0)
	want(t, r.stdout, "row claims 'hook yes' but the Stop hook is unwired at ")
	if r.stderr != "" {
		t.Errorf("stderr %q, want none: every hook-wiring check ran", r.stderr)
	}
}

func TestRegistrySessionBudgetThroughRunner(t *testing.T) {
	setup := func(t *testing.T) *vrKit {
		k := newVRKit(t)
		k.blocks("alpha", 1)
		k.put("alpha/.claude/settings.json", "{}\n")
		k.write("home/kit/toolbelt/verify-session-budget.sh", "#!/bin/sh\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
		return k
	}
	env := map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": "1"}
	t.Run("args-and-merged-streams", func(t *testing.T) {
		k := setup(t)
		var got []string
		withBudgetRunner(t, func(args []string, s cli.Stdio) int {
			got = args
			fmt.Fprintln(s.Out, "hook a status=TRUNCATED")
			fmt.Fprintln(s.Err, "state: degraded")
			return 0
		})
		r := k.run(env)
		wantArgs := []string{"--toolbelt", filepath.Join(k.kit, "toolbelt"), filepath.Join(k.home, "alpha")}
		if strings.Join(got, "|") != strings.Join(wantArgs, "|") {
			t.Errorf("runner args %q, want %q", got, wantArgs)
		}
		want(t, r.stdout, "a SessionStart hook emits more than 10,000 characters", "at least one SessionStart hook could not be measured")
		wantNot(t, r.stdout, "produced no 'state:' line")
		if r.stderr != "" {
			t.Errorf("stderr %q, want none", r.stderr)
		}
	})
	t.Run("usage-exit-reads-as-no-state", func(t *testing.T) {
		k := setup(t)
		withBudgetRunner(t, func(_ []string, s cli.Stdio) int { fmt.Fprintln(s.Err, "usage: x"); return cli.ExitUsage })
		want(t, k.run(env).stdout, "produced no 'state:' line")
	})
	t.Run("not-wired-is-counted-never-clean", func(t *testing.T) {
		k := setup(t)
		withBudgetRunner(t, nil)
		r := k.run(env)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: degraded: 1 hook-wiring/session-budget check(s) skipped; the session-budget meter is not wired into this build")
		wantNot(t, r.stdout, "SessionStart")
	})
}
