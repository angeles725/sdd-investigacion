//go:build !unix

package proc

import (
	"fmt"
	"io"
)

// HelperMain fails off unix: there are no rlimits to set.
func HelperMain(_, _ []string, stderr io.Writer) int {
	fmt.Fprintf(stderr, "rsdd %s: rlimits are unsupported on this platform\n", HelperCommand)
	return 125
}
