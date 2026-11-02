//go:build !unix

package floss

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Run is unavailable off unix: the analysis needs bubblewrap, process groups and rlimits.
func Run(_ []string, s cli.Stdio) int {
	fmt.Fprintln(s.Err, "corroborate-floss: requires a unix platform (bubblewrap, process groups and rlimits)")
	return cli.ExitOperational
}
