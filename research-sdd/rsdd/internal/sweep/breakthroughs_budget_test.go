package sweep

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// The SessionStart budget of the breakthroughs hook (kit issue #1816, openspec/specs/kit-session-cost), on a
// FROZEN reading of the real fleet: testdata/breakthroughs/hook/sweep-breakthroughs.raw is the output of the sweep
// (a dated, sanitised reading, never the live corpus). The cap is a budget assertion on that fixture, not the live
// aggregate reading. It replaces the brk-1..brk-5 cases and the "D" tooth of sessionstart-budget.test.sh, which
// replayed the same reading through the bash hook.

const (
	btRawPath = "testdata/breakthroughs/hook/sweep-breakthroughs.raw"
	btCapChar = 900 // characters of the hook's stdout
)

func btRaw(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(btRawPath)
	if err != nil || len(b) == 0 {
		t.Fatalf("the frozen reading %s is missing or empty: %v", btRawPath, err)
	}
	return strings.TrimRight(string(b), "\n")
}

// btStdout is what the hook prints for the reading: the envelope around its context.
func btStdout(raw string, full bool) string {
	var b bytes.Buffer
	hookenv.WriteSessionStart(&b, breakthroughsHookContext(raw, 0, full))
	return b.String()
}

func TestBreakthroughsBudget(t *testing.T) {
	raw := btRaw(t)
	if n := utf8.RuneCountInString(btStdout(raw, false)); n > btCapChar {
		t.Errorf("brk-1: the hook prints %d characters, cap %d", n, btCapChar)
	}
	ctx := breakthroughsHookContext(raw, 0, false)
	var summary string
	for _, l := range strings.Split(raw, "\n") {
		if strings.HasPrefix(l, "Summary:") {
			summary = l
		}
	}
	if summary == "" || !strings.Contains(ctx, summary) {
		t.Errorf("brk-2: the Summary line %q is altered or missing:\n%s", summary, ctx)
	}
	if !strings.Contains(ctx, "\nWARN: 18 unindexed breakthrough") {
		t.Errorf("brk-3: the unindexed count (18) is not stated:\n%s", ctx)
	}
	if !strings.Contains(ctx, "INFO: 15 target(s) not traversed (absent-input)") || !strings.Contains(ctx, "INFO: 2 corpus(es) empty-input, 15 no-match") {
		t.Errorf("brk-4: a section 7 state count is missing:\n%s", ctx)
	}
	full := breakthroughsHookContext(raw, 0, true)
	if n := strings.Count(full, "\nWARN: unindexed breakthrough"); n != 18 {
		t.Errorf("brk-5: --full lists %d unindexed lines, want 18", n)
	}
}

// The cap bites: the uncollapsed reading (what --full prints) is over it, so a hook that stopped collapsing would
// fail brk-1.
func TestBreakthroughsBudgetCapBites(t *testing.T) {
	if n := utf8.RuneCountInString(btStdout(btRaw(t), true)); n <= btCapChar {
		t.Errorf("the full reading is %d characters, within the cap %d: the cap does not bite", n, btCapChar)
	}
}
