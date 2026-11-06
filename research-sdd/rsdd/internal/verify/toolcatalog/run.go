package toolcatalog

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

// Run is `rsdd verify tool-catalog [<toolbelt-dir>]`: WARN for every tool logged in INSTALLED-TOOLS.md that
// tool-registry.md does not mention. The directory defaults to the working directory (the kit shim passes its own).
//
// Exit: 0 clean or advisory findings, 1 an input missing or unreadable, 2 usage.
func Run(args []string, s cli.Stdio) int {
	if len(args) > 1 || len(args) == 1 && args[0] == "" { // an empty operand would read /INSTALLED-TOOLS.md
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	dir := s.Cwd
	if len(args) == 1 {
		dir = args[0]
	}
	return check(fsview.View{Cwd: s.Cwd}, dir, localeOf(s.Env), s.Out, s.Err)
}
