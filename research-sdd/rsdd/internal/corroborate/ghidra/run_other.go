//go:build !unix

package ghidra

import (
	"fmt"
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Run refuses off Unix: the adapter needs Bubblewrap, /proc/self/fd and a Linux-private filesystem.
func Run(args []string, s cli.Stdio) int {
	if _, code, ok := parseArgs(args, s); !ok {
		return code
	}
	_, _ = io.WriteString(s.Err, fmt.Sprintln("corroborate-ghidra: unsupported platform (needs Linux)"))
	return cli.ExitUsage
}
