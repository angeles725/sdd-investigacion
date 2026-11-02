package verify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Teeth for `verify registry` (kit issue #2489): each test pins an effect that a counter, a boundary or a guard
// mutant of registry.go / registrychecks.go / kitclean.go used to leave unobserved. The equivalent mutants are
// listed at the end of this file.

// summaryLine is the report's exact Summary line. A substring such as "1 attention" also matches "-1 attention",
// which is how an inverted counter (++ -> --) stayed unseen, so the whole line is compared.
func summaryLine(checked, absent, drift, retro, unres, over, attn int) string {
	return fmt.Sprintf("Summary: reconciled %d target(s) · %d absent target(s) · %d count drift(s) · %d retro drift(s) · %d unresolvable · %d oversized row(s) · %d attention.\n",
		checked, absent, drift, retro, unres, over, attn)
}

func TestRegistryCountersExact(t *testing.T) {
	const noCountDrift, noRetroDrift = "For each count drift", "For each retro drift"
	cases := []struct {
		name    string
		setup   func(k *vrKit)
		env     map[string]string
		summary string
		out     []string
		notOut  []string
		skip    func() bool
	}{
		{"maturity-field", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / bogus)")))
		}, nil, summaryLine(2, 0, 0, 0, 1, 0, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"nc-contradiction", func(k *vrKit) {
			k.put("tool/a.md", "x\n")
			k.put("tool/b.md", "x\n")
			k.put("tool/RESEARCH-STATE.md", "s\n")
			k.targets(vrTable(vrRow("1", "tool", "tool", "(2 md / nc)")))
		}, nil, summaryLine(2, 0, 0, 0, 1, 0, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"nc-no-count", func(k *vrKit) {
			k.put("tool/a.md", "x\n")
			k.targets(vrTable(vrRow("1", "tool", "tool", "(1 run / nc)")))
		}, nil, summaryLine(2, 0, 0, 0, 1, 0, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"nc-count-drift", func(k *vrKit) {
			k.put("tool/a.md", "x\n")
			k.put("tool/b.md", "x\n")
			k.targets(vrTable(vrRow("1", "tool", "tool", "(9 md / nc)")))
		}, nil, summaryLine(2, 0, 1, 0, 0, 0, 0), []string{noCountDrift}, []string{noRetroDrift}, nil},
		{"corpus-unresolvable", func(k *vrKit) {
			k.put("bare/INDEX.md", "i\n")
			k.targets(vrTable(vrRow("1", "bare", "bare", "(1 md)")))
		}, nil, summaryLine(1, 0, 0, 0, 1, 0, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"no-claimed-count", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 focus)")))
		}, nil, summaryLine(2, 0, 0, 0, 1, 0, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"no-corpus-marker", func(k *vrKit) {
			k.put("deep/research/RESEARCH-STATE.md", "s\n")
			k.put("deep/research/p-block1.md", "b\n")
			k.targets(vrTable(vrRow("1", "deep", "deep", "(1 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"retros-unreadable", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.put("alpha/retros/r1.md", "# r\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 1 retro)")))
			dir := filepath.Join(k.home, "alpha/retros")
			if err := os.Chmod(dir, 0o000); err != nil {
				k.t.Fatal(err)
			}
			k.t.Cleanup(func() { os.Chmod(dir, 0o755) }) //nolint:errcheck
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, func() bool { return os.Geteuid() == 0 }},
		{"unclassifiable", func(k *vrKit) {
			k.put("alpha/RESEARCH-STATE.md", "s\n")
			k.put("alpha/block1.md", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(0 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"kit-not-registered", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.write("kit/TARGETS.md", "| 1 | alpha | `"+k.home+"/alpha` | (1 md) | x | en |\n")
		}, nil, summaryLine(1, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"catalog-unparseable", func(k *vrKit) {
			k.blocks("alpha", 5)
			k.put("alpha/retros/r.md", "x\n")
			k.catalog("alpha", "no digits here", 6)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(5 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"catalog-stale-header", func(k *vrKit) {
			k.blocks("alpha", 5)
			k.put("alpha/retros/r.md", "x\n")
			k.catalog("alpha", "Total: 9", 6)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(5 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"catalog-stale", func(k *vrKit) {
			k.blocks("alpha", 5)
			k.put("alpha/retros/r.md", "x\n")
			k.catalog("alpha", "Total: 12", 12)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(12 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"catalog-disc-zero", func(k *vrKit) {
			k.blocks("alpha", 0)
			k.put("alpha/retros/r.md", "x\n")
			k.catalog("alpha", "Total: 12", 12)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(12 md)")))
		}, nil, summaryLine(2, 0, 0, 0, 0, 0, 1), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"oversized-row", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.targets(vrTable("| 1 | alpha | `@H@/alpha` | (1 md) | " + strings.Repeat("x", 30) + " | en |"))
		}, map[string]string{"RSDD_ROW_MAXLEN": "25"}, summaryLine(2, 0, 0, 0, 0, 2, 0), nil, []string{noCountDrift, noRetroDrift}, nil},
		{"retro-drift-only", func(k *vrKit) {
			k.blocks("alpha", 1)
			k.put("alpha/retros/r1.md", "# r\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md / 5 retros)")))
		}, nil, summaryLine(2, 0, 0, 1, 0, 0, 0), []string{noRetroDrift}, []string{noCountDrift}, nil},
		{"count-drift-only", func(k *vrKit) {
			k.blocks("alpha", 5)
			k.put("alpha/retros/r1.md", "x\n")
			k.targets(vrTable(vrRow("1", "alpha", "alpha", "(8 md)")))
		}, nil, summaryLine(2, 0, 1, 0, 0, 0, 0), []string{noCountDrift}, []string{noRetroDrift}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.skip != nil && c.skip() {
				t.Skip("root bypasses directory permissions")
			}
			k := newVRKit(t)
			c.setup(k)
			r := k.run(c.env)
			rcIs(t, r, 0)
			want(t, r.stdout, append([]string{c.summary}, c.out...)...)
			wantNot(t, r.stdout, c.notOut...)
			if r.stderr != "" {
				t.Errorf("stderr %q, want none (no hook check was skipped)", r.stderr)
			}
		})
	}
}

// A corpus with no block file and no candidate names is not "unclassifiable", and a small corpus needs no retro
// feedback wiring: neither finding fires on a count of zero (or on a count within the tolerance).
func TestRegistryZeroUnclassifiableAndSmallCorpusAreQuiet(t *testing.T) {
	t.Run("empty-corpus", func(t *testing.T) {
		k := newVRKit(t)
		k.put("alpha/RESEARCH-STATE.md", "s\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(0 md)")))
		r := k.run(nil)
		wantNot(t, r.stdout, "unclassifiable", "no retros/*.md reachable")
		want(t, r.stdout, "Registry consistent with reality")
	})
	t.Run("within-tolerance", func(t *testing.T) {
		k := newVRKit(t)
		k.blocks("alpha", 1)
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
		r := k.run(nil)
		wantNot(t, r.stdout, "no retros/*.md reachable")
	})
	t.Run("tol-below-zero-names-blocks-not-candidates", func(t *testing.T) {
		k := newVRKit(t)
		k.put("alpha/RESEARCH-STATE.md", "s\n")
		k.targets(vrTable(vrRow("1", "alpha", "alpha", "(0 md)")))
		r := k.run(map[string]string{"RSDD_REGISTRY_TOL": "-1"})
		want(t, r.stdout, "INFO  alpha — 0 block(s) on disk but no retros/*.md reachable under the target (§18 feedback not wired).\n")
		wantNot(t, r.stdout, "(unclassifiable) on disk")
	})
}

func TestRegistryAbsentNamesAndMore(t *testing.T) {
	absent := func(n int) string {
		k := newVRKit(t)
		k.blocks("here", 1)
		rows := []string{vrRow("1", "here", "here", "(1 md)")}
		for i := 1; i <= n; i++ {
			g := fmt.Sprintf("g%d", i)
			rows = append(rows, vrRow(fmt.Sprint(i+1), g, g, "(1 md)"))
		}
		k.targets(vrTable(rows...))
		return k.run(nil).stdout
	}
	out := absent(1)
	want(t, out, "NOT checked: `$RESEARCH_HOME/g1`. Verify RESEARCH_HOME (")
	wantNot(t, out, "...and")
	out = absent(3)
	want(t, out, "`$RESEARCH_HOME/g1`, `$RESEARCH_HOME/g2`, `$RESEARCH_HOME/g3`. Verify RESEARCH_HOME (")
	wantNot(t, out, "...and")
	want(t, absent(4), "`$RESEARCH_HOME/g3` ...and 1 more. Verify")
}

// A master row of exactly three '|'-separated fields (no closing pipe) still names itself in the lint.
func TestRegistryRowHygieneThreeFieldRow(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")) + "| 7 | longnamehere\n")
	r := k.run(map[string]string{"RSDD_ROW_MAXLEN": "11"})
	want(t, r.stdout, "WARN  TARGETS row longnamehere master cell is 12 chars (> 11) — collapse to one line; narrative belongs in the detail section.\n")
	wantNot(t, r.stdout, "TARGETS row ?")
}

func TestRegistryKitFlag(t *testing.T) {
	t.Run("missing-directory-after-last-flag", func(t *testing.T) {
		k := newVRKit(t)
		k.targets(vrTable())
		r := k.run(nil, "--kit")
		rcIs(t, r, 2)
		if r.stdout != "" || r.stderr != "verify-registry: --kit needs a directory\nusage: verify-registry.sh [--json]\n" {
			t.Errorf("stdout=%q stderr=%q", r.stdout, r.stderr)
		}
	})
	t.Run("symlinked-kit-is-reported-by-its-physical-path", func(t *testing.T) {
		k := newVRKit(t)
		link := filepath.Join(k.root, "kitlink")
		if err := os.Symlink(filepath.Join(k.root, "emptykit"), link); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(k.root, "emptykit"), 0o755); err != nil {
			t.Fatal(err)
		}
		r := k.run(nil, "--kit", link)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: cannot find "+filepath.Join(k.root, "emptykit")+"/TARGETS.md\n")
	})
	t.Run("unresolvable-kit-keeps-the-given-path", func(t *testing.T) {
		k := newVRKit(t)
		missing := filepath.Join(k.root, "nowhere")
		r := k.run(nil, "--kit", missing)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: cannot find "+missing+"/TARGETS.md\n")
	})
}

func TestRegistrySessionBudgetAggregateWithoutChars(t *testing.T) {
	k := newVRKit(t)
	k.blocks("alpha", 1)
	k.put("alpha/.claude/settings.json", "{}\n")
	k.write("kit/toolbelt/verify-session-budget.sh", "#!/bin/sh\n")
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(1 md)")))
	// " worst-source=" at offset 0 of the text after "aggregate: " is still a worst source
	withHooks(t, fakeHooks{budgetOK: true, budget: "OVER BUDGET\naggregate:  worst-source=startup\nstate: ok\n"})
	r := k.run(map[string]string{"RSDD_REGISTRY_SESSION_BUDGET": "1"})
	want(t, r.stdout, "(worst session source: startup; run verify-session-budget.sh")
}

// The wiring state, not the script state, decides whether the script check runs: an unwired hook never reaches
// it, so a stale fake script answer must not change the report.
func TestRegistryHookScriptCheckOnlyForWiredStates(t *testing.T) {
	cases := []struct {
		name, cell string
		h          fakeHooks
		out        string
		notOut     string
	}{
		{"nosess-unwired-ignores-script-answer", "(1 md / hook file yes / registered-no-sessions)", fakeHooks{wiring: "unwired", script: "present", launch: "launched"},
			"(wiring unwired, script n/a)", "a retained Claude Code transcript now exists"},
		{"nosess-off-root-reads-script-answer", "(1 md / hook file yes / registered-no-sessions)", fakeHooks{wiring: "wired-off-root", script: "missing", launch: "launched"},
			"(wiring wired-off-root, script missing)", "script n/a"},
		{"unreg-unwired-ignores-script-answer", "(1 md / hook file yes / unregistered)", fakeHooks{wiring: "unwired", script: "present", launch: "launched"},
			"", "row claims 'unregistered' but the Stop hook IS registered"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			k := newVRKit(t)
			k.blocks("alpha", 1)
			k.targets(vrTable(vrRow("1", "alpha", "alpha", c.cell)))
			withHooks(t, c.h)
			r := k.run(nil)
			if c.out != "" {
				want(t, r.stdout, c.out)
			}
			wantNot(t, r.stdout, c.notOut)
		})
	}
}

func TestGitConfigCountEnvBoundaries(t *testing.T) {
	envOf := func(m map[string]string) cli.Stdio { return cli.Stdio{Env: func(k string) string { return m[k] }} }
	t.Run("count-at-the-bound-keeps-its-pairs", func(t *testing.T) {
		got := gitConfigCountEnv(envOf(map[string]string{"GIT_CONFIG_COUNT": "1000", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "v", "GIT_CONFIG_KEY_999": "c.d", "GIT_CONFIG_VALUE_999": "w"}))
		if strings.Join(got, "\n") != "GIT_CONFIG_COUNT=1000\nGIT_CONFIG_KEY_0=a.b\nGIT_CONFIG_VALUE_0=v\nGIT_CONFIG_KEY_999=c.d\nGIT_CONFIG_VALUE_999=w" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("count-above-the-bound-is-passed-alone", func(t *testing.T) {
		got := gitConfigCountEnv(envOf(map[string]string{"GIT_CONFIG_COUNT": "1001", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "v"}))
		if strings.Join(got, "\n") != "GIT_CONFIG_COUNT=1001" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("the-pair-numbered-count-is-not-read", func(t *testing.T) {
		got := gitConfigCountEnv(envOf(map[string]string{"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "v", "GIT_CONFIG_KEY_1": "c.d", "GIT_CONFIG_VALUE_1": "w"}))
		if strings.Join(got, "\n") != "GIT_CONFIG_COUNT=1\nGIT_CONFIG_KEY_0=a.b\nGIT_CONFIG_VALUE_0=v" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("negative-count-is-passed-alone", func(t *testing.T) {
		got := gitConfigCountEnv(envOf(map[string]string{"GIT_CONFIG_COUNT": "-1", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "v"}))
		if strings.Join(got, "\n") != "GIT_CONFIG_COUNT=-1" {
			t.Errorf("got %q", got)
		}
	})
}

// teeth: equivalent mutant registry.go:263:7 — absDiff(a, a) is 0 on either branch (a<b vs a<=b)
// teeth: equivalent mutant registry.go:367:14 — dirReached is only compared with 0 and only ever incremented, so -- also never returns to 0
// teeth: equivalent mutant registry.go:553:10 — rows<=0 assigns 0 to a rows that is already 0
// teeth: equivalent mutant registry.go:584:24 — strings.Split always returns at least one element, so n>0 and n>=0 agree
// teeth: equivalent mutant registry.go:627:25 — max is non-numeric here and Itoa(n) is digits only, so the two strings are never equal and > equals >=
// teeth: equivalent mutant kitclean.go:76:21 — n<=0 only adds n==0, whose loop body never runs, so the env is the count alone either way
