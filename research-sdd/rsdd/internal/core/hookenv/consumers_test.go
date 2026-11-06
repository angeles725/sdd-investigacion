package hookenv

import (
	"encoding/json"
	"os"
	"path"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// maxKitPath is the longest kit checkout path the pi bound allows for: pi prints the kit path in its header and its
// drift line, so a longer path leaves less room per hook.
const maxKitPath = 256

// claudeBudget is the kit's SessionStart budget (openspec/specs/kit-session-cost/spec.md: under 8,000 characters).
const claudeBudget = 8000

// registeredHooks is the SessionStart hook list of the kit's own .claude/settings.json, by script name.
func registeredHooks(t *testing.T) []string {
	b, err := os.ReadFile(kitroot.Path(t, "..", ".claude", "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var s struct {
		Hooks map[string][]struct{ Hooks []struct{ Command string } }
	}
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, g := range s.Hooks["SessionStart"] {
		for _, h := range g.Hooks {
			names = append(names, strings.TrimSuffix(path.Base(strings.Trim(h.Command, `"`)), ".sh"))
		}
	}
	if len(names) == 0 {
		t.Fatal("no SessionStart hook is registered in .claude/settings.json: the bound would hold vacuously")
	}
	return names
}

// cappedHooks are the registered hooks whose could-not-run context goes through FailureContext, by script name (the
// script is a shim that runs the rsdd command named here).
var cappedHooks = map[string]string{
	"sweep-retros-hook":        "rsdd sweep retros --hook",
	"sweep-audits-hook":        "rsdd sweep audits --hook",
	"sweep-breakthroughs-hook": "rsdd sweep breakthroughs --hook",
	"sweep-tools-hook":         "rsdd sweep tools --hook",
	"verify-registry-hook":     "rsdd verify registry-hook",
	"verify-kit-clean-hook":    "rsdd verify kit-clean-hook",
	"verify-skill-drift-hook":  "rsdd verify skill-drift --hook",
}

// uncappedHooks are registered hooks that still print their whole could-not-run output: debt, each with its issue.
// Its port removes the entry here and adds one to cappedHooks.
var uncappedHooks = map[string]string{
	"verify-tool-catalog-hook": "#2749: still bash (lib/hook-emit.sh does not trim)",
}

// Every registered hook is either capped or a named debt: a ninth hook, or a capped hook that goes back to bash,
// turns this red instead of silently widening the session's worst case.
func TestEveryRegisteredHookIsCappedOrNamedDebt(t *testing.T) {
	reg := registeredHooks(t)
	for _, h := range reg {
		_, capped := cappedHooks[h]
		_, debt := uncappedHooks[h]
		if capped == debt {
			t.Errorf("hook %s: capped %v, named debt %v (exactly one must hold)", h, capped, debt)
		}
	}
	if len(reg) != len(cappedHooks)+len(uncappedHooks) {
		t.Errorf("%d registered hooks, %d capped + %d debt: an entry names no registered hook", len(reg), len(cappedHooks), len(uncappedHooks))
	}
	for h, why := range uncappedHooks {
		t.Logf("uncapped SessionStart hook %s (%s): the worst case below holds for the other %d hooks only", h, why, len(cappedHooks))
	}
	// Each capped shim really runs the command whose failure path is capped.
	for h, cmd := range cappedHooks {
		b, err := os.ReadFile(kitroot.Path(t, "toolbelt", h+".sh"))
		if err != nil {
			t.Fatal(err)
		}
		// the first word after rsdd_exec_hook is the hook kind, "sweep" for every SessionStart hook
		if want := "rsdd_exec_hook sweep " + strings.TrimPrefix(cmd, "rsdd "); !strings.Contains(string(b), want) {
			t.Errorf("%s.sh does not run %q", h, want)
		}
	}
}

// piSource is the pi extension that joins the hooks' contexts.
func piSource(t *testing.T) string {
	b, err := os.ReadFile(kitroot.Path(t, "install", "pi", "research-sdd-hooks.ts"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func submatch(t *testing.T, src, re string) []string {
	t.Helper()
	m := regexp.MustCompile(re).FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("research-sdd-hooks.ts no longer matches %s: re-derive the bound in hookenv/failure.go", re)
	}
	return m
}

func atoi(t *testing.T, s string) int {
	t.Helper()
	n, err := strconv.Atoi(s)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// The pi extension runs the same hooks the claude harness registers: a hook added on one side only is a hook whose
// share the bound below never counted.
func TestPiRunsTheRegisteredHooks(t *testing.T) {
	reg := registeredHooks(t)
	m := submatch(t, piSource(t), `(?s)const SWEEP_HOOKS = \[(.*?)\];`)
	var pi []string
	for _, q := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(m[1], -1) {
		pi = append(pi, q[1])
	}
	slices.Sort(reg)
	slices.Sort(pi)
	if !slices.Equal(reg, pi) {
		t.Fatalf("SessionStart hooks differ:\n.claude/settings.json %v\nresearch-sdd-hooks.ts %v", reg, pi)
	}
}

// Every registered hook failing at once at FailureCap fits both consumers (see the FailureCap doc).
func TestFailureCapFitsEveryConsumer(t *testing.T) {
	hooks := registeredHooks(t)
	n := len(hooks)
	if max := (claudeBudget - 1) / n; FailureCap > max {
		t.Errorf("claude: %d hooks x FailureCap %d >= %d; the largest cap is %d", n, FailureCap, claudeBudget, max)
	}

	src := piSource(t)
	maxContext := atoi(t, submatch(t, src, `const MAX_CONTEXT_CHARS = ([0-9]+);`)[1])
	margin := atoi(t, submatch(t, src, `const budget = MAX_CONTEXT_CHARS - lines\.join\("\\n"\)\.length - ([0-9]+);`)[1])
	submatch(t, src, `const total = withText\.reduce\(\(n, r\) => n \+ r\.text\.length \+ r\.name\.length \+ 4, 0\);`)
	header := "Research-SDD session sweep (kit " + strings.Repeat("k", maxKitPath) + "): " +
		strconv.Itoa(n) + " of " + strconv.Itoa(n) + " hooks ran, " + strconv.Itoa(n) + " with findings."
	submatch(t, src, regexp.QuoteMeta("`Research-SDD session sweep (kit ${st.kit}): ${results.length - bad.length} of ${results.length} hooks ran, ${withText.length} with findings`"))
	names := 0
	for _, h := range hooks {
		names += len(h) + 4
	}
	// No head cut: total <= budget, where total = sum(text + name + 4) and budget = maxContext - header - margin.
	piMax := (maxContext - Width(header) - margin - names) / n
	// No whole-string cut either: header, then "[name] text" per hook, then the drift line, joined by newlines.
	drift := "Drift fix (re-renders the deployed skill, launcher and this extension): bash " + strings.Repeat("k", maxKitPath) +
		"/install/research-sdd-install.sh --harness gentle-shell"
	submatch(t, src, regexp.QuoteMeta("`Drift fix (re-renders the deployed skill, launcher and this extension): bash ${st.kit}/install/research-sdd-install.sh --harness ${harnessOf(st.home)}`"))
	fixed := Width(header) + 1 + Width(drift)
	for _, h := range hooks {
		fixed += len(h) + 3 + 1
	}
	if whole := (maxContext - fixed) / n; whole < piMax {
		piMax = whole
	}
	if FailureCap > piMax {
		t.Errorf("pi: %d hooks at FailureCap %d pass its %d-character sweep budget; the largest cap is %d", n, FailureCap, maxContext, piMax)
	}
	t.Logf("%d hooks: claude allows %d per hook, pi %d (kit path <= %d); FailureCap = %d", n, (claudeBudget-1)/n, piMax, maxKitPath, FailureCap)
}
