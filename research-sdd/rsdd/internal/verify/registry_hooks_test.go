package verify

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// fakeHooks answers the registryHooks questions from fixed values, so the sections that read hook wiring are
// pinned without bash. The differential test runs the same sections against the legacy lib/hook-wiring.sh.
type fakeHooks struct {
	wiring, script, launch string
	exec                   []wiredExec
	budget                 string
	budgetOK               bool
}

func (f fakeHooks) StopWiringState(string) (string, bool) { return f.wiring, true }
func (f fakeHooks) StopScriptState(string) (string, bool) { return f.script, true }
func (f fakeHooks) StopLaunchState(string) (string, bool) { return f.launch, true }
func (f fakeHooks) WiredExecReport(string) ([]wiredExec, bool) {
	return f.exec, true
}
func (f fakeHooks) SessionBudget(string) (string, bool) { return f.budget, f.budgetOK }

// withHooks installs h for one test; the factory is package state, so these tests never run in parallel.
func withHooks(t *testing.T, h registryHooks) {
	t.Helper()
	old := newRegistryHooks
	newRegistryHooks = func(cli.Stdio) registryHooks { return h }
	t.Cleanup(func() { newRegistryHooks = old })
}

func TestRegistryHookSections(t *testing.T) {
	const sf = "/.claude/settings.json"
	note := "(checked path only — settings.local.json and user-level ~/.claude/settings.json are not inspected)"
	cases := []struct {
		name     string
		cell     string
		h        fakeHooks
		out      []string
		notOut   []string
		attn     string
		dotClaud bool
	}{
		{"yes-wired-ok", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "present", launch: "launched"}, nil, []string{"WARN"}, "0 attention", false},
		{"yes-unwired", "(1 md / hook yes)", fakeHooks{wiring: "unwired"},
			[]string{"WARN  alpha — row claims 'hook yes' but the Stop hook is unwired at @H" + sf + " " + note + "; refresh the row or wire the hook (propose-never-apply).\n"}, nil, "1 attention", false},
		{"yes-off-root", "(1 md / hook yes)", fakeHooks{wiring: "wired-off-root", script: "present", launch: "launched"},
			[]string{"row claims 'hook yes' but @H is not its own git root; the hook is expected to fire only for a session launched in exactly that directory"}, nil, "1 attention", false},
		{"yes-never-loaded", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "missing", launch: "no-sessions"},
			[]string{"registered-never-loaded; checked path only"}, []string{"is not its own git root", "no retained Claude Code transcript"}, "1 attention", false},
		{"yes-off-root-script-missing", "(1 md / hook yes)", fakeHooks{wiring: "wired-off-root", script: "missing"},
			[]string{"registered-never-loaded; checked path only"}, []string{"is not its own git root"}, "1 attention", false},
		{"yes-absent-settings-has-no-script-check", "(1 md / hook yes)", fakeHooks{wiring: "absent-settings", script: "missing", launch: "no-sessions"},
			[]string{"the Stop hook is absent-settings at"}, []string{"registered-never-loaded", "no retained Claude Code transcript"}, "1 attention", false},
		{"yes-script-degraded", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "degraded", launch: "launched"},
			[]string{"the script-resolution check degraded (awk unavailable or failed)"}, nil, "1 attention", false},
		{"yes-no-sessions", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "present", launch: "no-sessions"},
			[]string{"but there is no retained Claude Code transcript for a session launched from exactly @H"}, nil, "1 attention", false},
		{"yes-unverifiable-silent", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "unverifiable", launch: "unknown"}, nil, []string{"WARN"}, "0 attention", false},
		{"yes-case-and-suffix", "(1 md / Hook YES x2)", fakeHooks{wiring: "unwired"}, []string{"row claims 'Hook YES x2' but the Stop hook is unwired"}, nil, "1 attention", false},
		{"yes-not-a-word", "(1 md / hook yesterday)", fakeHooks{wiring: "unwired"}, nil, []string{"row claims"}, "0 attention", false},
		{"file-unreg-stale-nosess", "(1 md / hook file yes / unregistered)", fakeHooks{wiring: "wired", script: "present", launch: "no-sessions"},
			[]string{"row claims 'unregistered' but the Stop hook IS registered at @H" + sf + " " + note + "; there is no retained Claude Code transcript for a session launched from exactly @H, so the accurate token is 'registered-no-sessions'; refresh the row (propose-never-apply).\n"}, nil, "1 attention", false},
		{"file-unreg-stale-case", "(1 md / Hook File YES / unregistered)", fakeHooks{wiring: "wired", script: "present", launch: "launched"},
			[]string{"row claims 'unregistered' but the Stop hook IS registered"}, nil, "1 attention", false},
		{"file-unreg-stale-launched", "(1 md / hook file yes / unregistered)", fakeHooks{wiring: "wired", script: "present", launch: "launched"},
			[]string{"the accurate claim is likely 'hook yes'; refresh the row"}, nil, "1 attention", false},
		{"file-unreg-stale-unknown", "(1 md / hook file yes / unregistered)", fakeHooks{wiring: "wired", script: "present", launch: "unknown"},
			[]string{"the launch history could not be read (launch unknown)"}, nil, "1 attention", false},
		{"file-unreg-true", "(1 md / hook file yes / unregistered)", fakeHooks{wiring: "unwired"}, nil, []string{"WARN"}, "0 attention", false},
		{"file-nosess-stale-launched", "(1 md / hook file yes / registered-no-sessions)", fakeHooks{wiring: "wired", script: "present", launch: "launched"},
			[]string{"row claims 'registered-no-sessions' but a retained Claude Code transcript now exists"}, nil, "1 attention", false},
		{"file-nosess-unwired", "(1 md / hook file yes / registered-no-sessions)", fakeHooks{wiring: "unwired"},
			[]string{"(wiring unwired, script n/a); refresh the row (propose-never-apply).\n"}, nil, "1 attention", false},
		{"file-nosess-missing", "(1 md / hook file yes / registered-no-sessions)", fakeHooks{wiring: "wired", script: "missing"},
			[]string{"(wiring wired, script missing)"}, nil, "1 attention", false},
		{"no-wired", "(1 md / hook no)", fakeHooks{wiring: "wired", script: "present"},
			[]string{"row claims 'hook no' but the Stop hook IS wired at @H" + sf + " " + note + "; at minimum this needs 'hook file yes ...'"}, nil, "1 attention", false},
		{"no-wired-script-missing", "(1 md / hook no)", fakeHooks{wiring: "wired", script: "missing"}, nil, []string{"WARN"}, "0 attention", false},
		{"no-off-root", "(1 md / hook no)", fakeHooks{wiring: "wired-off-root", script: "present"}, nil, []string{"WARN"}, "0 attention", false},
		{"exec", "(1 md)", fakeHooks{exec: []wiredExec{
			{"unverifiable", "bash -c x", "interpreter option"}, {"not-executable", "/abs/a.sh", "SessionStart"},
			{"missing", "/abs/b.sh", "SessionStart"}, {"ok", "/abs/c.sh", "x"}, {"", "", ""}}},
			[]string{
				"WARN  alpha — wired-hook-unverifiable: bash -c x (interpreter option); whether this wired hook can run was NOT determined (checked path only: @H" + sf + "; propose-never-apply).\n",
				"WARN  alpha — wired-hook-not-executable: /abs/a.sh is registered in @H" + sf + " as a bare command but has no execute bit, so Claude Code exits 126 and the hook never loads; chmod +x it or wire it as 'bash <path>' (propose-never-apply).\n",
				"WARN  alpha — wired-hook-missing: /abs/b.sh is registered in @H" + sf + " but no such file exists, so the hook can never run; restore it or remove the registration (propose-never-apply).\n"},
			nil, "3 attention", true},
		{"exec-dedup-never-loaded", "(1 md / hook yes)", fakeHooks{wiring: "wired", script: "missing", exec: []wiredExec{{"missing", "/abs/x/retro-gate.sh", "Stop"}, {"missing", "/abs/y.sh", "Stop"}}},
			[]string{"registered-never-loaded", "wired-hook-missing: /abs/y.sh"}, []string{"wired-hook-missing: /abs/x/retro-gate.sh"}, "2 attention", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			k := newVRKit(t)
			k.blocks("alpha", 1)
			k.put("alpha/.claude/", "")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", c.cell)))
			withHooks(t, c.h)
			r := k.run(nil)
			rcIs(t, r, 0)
			sub := func(xs []string) []string {
				out := make([]string, len(xs))
				for i, x := range xs {
					out[i] = strings.ReplaceAll(x, "@H", k.home+"/alpha")
				}
				return out
			}
			want(t, r.stdout, sub(c.out)...)
			wantNot(t, r.stdout, sub(c.notOut)...)
			want(t, r.stdout, " · "+c.attn+".\n") // the whole counter: "1 attention" alone also matches "-1 attention"
			if r.stderr != "" {
				t.Errorf("stderr %q, want none (every hook check ran)", r.stderr)
			}
		})
	}
}

func TestRegistrySessionBudget(t *testing.T) {
	run := func(t *testing.T, h fakeHooks, missingScript bool) vrResult {
		k := newVRKit(t)
		k.blocks("alpha", 1)
		k.put("alpha/.claude/settings.json", "{}\n")
		if !missingScript {
			k.write("kit/toolbelt/verify-session-budget.sh", "#!/bin/sh\n")
		}
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
		withHooks(t, h)
		return k.run(map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": "1"})
	}
	t.Run("off-by-default", func(t *testing.T) {
		k := newVRKit(t)
		k.blocks("alpha", 1)
		k.put("alpha/.claude/settings.json", "{}\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
		withHooks(t, fakeHooks{budgetOK: true, budget: "status=TRUNCATED\n"})
		wantNot(t, k.run(nil).stdout, "SessionStart")
	})
	t.Run("off-unless-exactly-1", func(t *testing.T) {
		for _, v := range []string{"0", "yes", "11"} {
			k := newVRKit(t)
			k.blocks("alpha", 1)
			k.put("alpha/.claude/settings.json", "{}\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
			withHooks(t, fakeHooks{budgetOK: true, budget: "status=TRUNCATED\n"})
			wantNot(t, k.run(map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": v}).stdout, "SessionStart")
		}
	})
	t.Run("missing-script", func(t *testing.T) {
		r := run(t, fakeHooks{}, true)
		want(t, r.stdout, "SessionStart budget check could not run: verify-session-budget.sh is missing beside verify-registry.sh (a degraded measurement, not a zero).")
	})
	t.Run("findings", func(t *testing.T) {
		r := run(t, fakeHooks{budgetOK: true, budget: "hook a status=TRUNCATED\nhook b status=timed-out\naggregate: 9123 chars worst-source=startup\nOVER BUDGET\nstate: degraded\n"}, false)
		want(t, r.stdout, "a SessionStart hook emits more than 10,000 characters", "a SessionStart hook outlives its own configured timeout",
			"SessionStart hooks total 9123 characters, over the kit's 8,000-char budget (worst session source: startup; run verify-session-budget.sh",
			"at least one SessionStart hook could not be measured")
		wantNot(t, r.stdout, "produced no 'state:' line")
	})
	// Each rule fires without its usual partner (old bash cases 2129g and 2129d): a timed-out hook WARNs even when
	// the meter reports state: ok, and a degraded hook never reads as truncated.
	t.Run("timed-out-with-state-ok", func(t *testing.T) {
		r := run(t, fakeHooks{budgetOK: true, budget: "hook b status=timed-out\nstate: ok\n"}, false)
		want(t, r.stdout, "a SessionStart hook outlives its own configured timeout")
		wantNot(t, r.stdout, "could not be measured", "more than 10,000 characters")
	})
	t.Run("degraded-only-is-not-truncated", func(t *testing.T) {
		r := run(t, fakeHooks{budgetOK: true, budget: "hook c status=degraded(exit 1)\nstate: degraded\n"}, false)
		want(t, r.stdout, "at least one SessionStart hook could not be measured")
		wantNot(t, r.stdout, "more than 10,000 characters", "outlives its own configured timeout")
	})
	t.Run("no-state", func(t *testing.T) {
		r := run(t, fakeHooks{budgetOK: true, budget: "crashed\n"}, false)
		want(t, r.stdout, "produced no 'state:' line")
	})
	t.Run("clean", func(t *testing.T) {
		r := run(t, fakeHooks{budgetOK: true, budget: "state: ok\n"}, false)
		wantNot(t, r.stdout, "SessionStart")
	})
}
