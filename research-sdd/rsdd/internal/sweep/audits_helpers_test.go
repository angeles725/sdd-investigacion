package sweep

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// auditText is the body of the standard test audit: an optional marker line, then n numbered claim rows (the
// shape the sweep counts as audited claims).
func auditText(marker string, n int) string {
	var b strings.Builder
	if marker != "" {
		b.WriteString(marker + "\n")
	}
	b.WriteString("# audit\n\n## Audited claims\n\n| # | claim | verdict |\n|---|---|---|\n")
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "| %d | claim %d | CONFIRMED |\n", i, i)
	}
	return b.String()
}

// audit writes <tgt>/audits/<name>.
func (w *world) audit(tgt, name, marker string, n int) {
	w.t.Helper()
	w.put(tgt+"/audits/"+name, auditText(marker, n))
}

// runAudits runs `rsdd sweep audits --kit <kit> <args>` in process.
func (w *world) runAudits(args ...string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := cli.Run(Commands, append([]string{"sweep", "audits", "--kit", w.kit}, args...), w.stdio(&o, &e))
	return result{o.String(), e.String(), rc}
}

// runAuditsHook runs `rsdd sweep audits --hook`.
func (w *world) runAuditsHook(args ...string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := cli.Run(Commands, append([]string{"sweep", "audits", "--hook", "--kit", w.kit}, args...), w.stdio(&o, &e))
	return result{o.String(), e.String(), rc}
}
