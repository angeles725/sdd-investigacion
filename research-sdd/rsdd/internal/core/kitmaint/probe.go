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

// ProbeDeps prints the typed degraded line `<tool>: degraded: missing runtime dependency: a b` on out and returns
// false when any dependency is missing (CLAUDE.md section 7: a probe at startup, never a silent pass).
func ProbeDeps(out io.Writer, tool string, environ []string, cwd string, deps ...string) bool {
	missing := MissingDeps(environ, cwd, deps...)
	if len(missing) == 0 {
		return true
	}
	fmt.Fprintf(out, "%s: degraded: missing runtime dependency: %s\n", tool, strings.Join(missing, " "))
	return false
}
