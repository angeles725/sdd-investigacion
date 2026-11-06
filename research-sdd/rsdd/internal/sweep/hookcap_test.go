package sweep

import (
	"fmt"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// What a failed sweep (rc != 0) or a recovered panic (rc 1, hookenv.Guard) leaves in the hook's buffer.
func longFailure() string {
	var b strings.Builder
	b.WriteString("rsdd: internal-error: cannot read TARGETS.md\n")
	for i := 0; i < 300; i++ {
		fmt.Fprintf(&b, "WARN  target-%03d — something long enough to matter in the session budget\n", i)
	}
	b.WriteString("sweep: the last line")
	return b.String()
}

// Every sweep hook caps its could-not-run context (#2631): both the panic path and a failed sweep reach the hook's
// context function with rc != 0, so this pins both, plus a short failure passing through byte-identical.
func TestSweepHooksCapTheirFailureContext(t *testing.T) {
	hooks := []struct {
		name, header, rerun string
		ctx                 func(out string, rc int) string
	}{
		{"retros", fmt.Sprintf(hookFailedFmt, 1), retrosRerun, func(o string, rc int) string { return hookContext(o, rc, false) }},
		{"audits", fmt.Sprintf(auditsHookFailedFmt, 1), auditsRerun, func(o string, rc int) string { return auditsHookContext(o, rc, false) }},
		{"breakthroughs", fmt.Sprintf(btHookFailedFmt, 1), btRerun, func(o string, rc int) string { return breakthroughsHookContext(o, rc, false) }},
		{"tools", fmt.Sprintf(toolsHookFailedFmt, 1), toolsRerun, func(o string, rc int) string { c, _ := toolsHookContext(o, rc); return c }},
	}
	for _, h := range hooks {
		t.Run(h.name, func(t *testing.T) {
			if got := h.ctx("short failure", 1); got != h.header+"\nshort failure" {
				t.Errorf("a short failure changed: %q", got)
			}
			got := h.ctx(longFailure(), 1)
			if w := hookenv.Width(got); w > hookenv.FailureCap {
				t.Errorf("width %d > cap %d", w, hookenv.FailureCap)
			}
			if !strings.HasPrefix(got, h.header+"\nrsdd: internal-error: cannot read TARGETS.md\n") ||
				!strings.HasSuffix(got, "\nsweep: the last line") || !strings.Contains(got, "`"+h.rerun+"`") {
				t.Errorf("context:\n%s", got)
			}
		})
	}
}

// Each rerun hint names a command of this domain.
func TestSweepHookRerunCommandsExist(t *testing.T) {
	for _, r := range []string{retrosRerun, auditsRerun, btRerun, toolsRerun} {
		f := strings.Fields(r)
		found := false
		for _, c := range Commands {
			found = found || (len(f) == 3 && f[0] == "rsdd" && f[1] == c.Group && f[2] == c.Name)
		}
		if !found {
			t.Errorf("%q names no command of the sweep table", r)
		}
	}
}

// A census that ran but printed no Summary line is a broken instrument: its context is capped like a failure.
func TestToolsHookNoSummaryIsCapped(t *testing.T) {
	got, emit := toolsHookContext(strings.ReplaceAll(longFailure(), "Summary", "Summ"), 0)
	if !emit || hookenv.Width(got) > hookenv.FailureCap || !strings.HasPrefix(got, toolsHookNoSummary+"\n") ||
		!strings.HasSuffix(got, "\nsweep: the last line") {
		t.Errorf("emit %v, width %d:\n%s", emit, hookenv.Width(got), got)
	}
}
