package sweep

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// usageFailure reports a bad command line of sweep <name>. Plain mode is a usage error on stderr. Hook mode keeps the
// hook contract (exit 0, nothing on stderr, never block the session start): the same line goes into the hook's own
// "could not run" context with the usage exit code.
func usageFailure(s cli.Stdio, o options, name, hookFailedFmt string, err error) int {
	msg := fmt.Sprintf("sweep-%s: %v", name, err)
	if o.hook {
		hookenv.WriteSessionStart(s.Out, fmt.Sprintf(hookFailedFmt, cli.ExitUsage)+"\n"+msg)
		return cli.ExitOK
	}
	fmt.Fprintln(s.Err, msg)
	return cli.ExitUsage
}
