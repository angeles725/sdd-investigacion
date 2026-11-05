package kitmaint

import (
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// MissingDeps is kit_probe_deps: the names in deps that are not on PATH, in order.
func MissingDeps(environ []string, cwd string, deps ...string) []string {
	pr := probe.New(environ, cwd)
	var missing []string
	for _, d := range deps {
		if _, err := pr.LookPath(d); err != nil {
			missing = append(missing, d)
		}
	}
	return missing
}

// ProbeDeps prints the typed degraded state of a missing dependency (CLAUDE.md section 7: a probe at startup, never a
// silent pass) and returns false: `<tool>: degraded: missing runtime dependency: a b` on out, as the bash tool did,
// and `DEGRADED: missing runtime dependency: a b` on errw, the rsdd process contract.
func ProbeDeps(out, errw io.Writer, tool string, environ []string, cwd string, deps ...string) bool {
	missing := MissingDeps(environ, cwd, deps...)
	if len(missing) == 0 {
		return true
	}
	list := strings.Join(missing, " ")
	fmt.Fprintf(out, "%s: degraded: missing runtime dependency: %s\n", tool, list)
	fmt.Fprintf(errw, "DEGRADED: missing runtime dependency: %s\n", list)
	return false
}
