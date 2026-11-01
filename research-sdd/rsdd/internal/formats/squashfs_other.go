//go:build !unix

package formats

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// SquashfsExtract is unavailable off unix: the extraction needs bubblewrap, process groups and rlimits.
func SquashfsExtract(_ []string, s cli.Stdio) int {
	fmt.Fprintln(s.Err, "squashfs-extract: requires a unix platform (bubblewrap, process groups and rlimits)")
	return cli.ExitOperational
}
