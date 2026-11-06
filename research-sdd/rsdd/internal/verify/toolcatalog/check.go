package toolcatalog

import (
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

// input is one of the two files of the check: its path as the report prints it, and its text once read.
type input struct{ path, text string }

// readInput reads name below dir. A file that is not there (or is not a regular file) is the absent-input state; one
// that is there and cannot be read is an operational failure of its own, never an empty read.
func readInput(v fsview.View, dir, name string, errw io.Writer) (input, bool) {
	in := input{path: strings.TrimSuffix(dir, "/") + "/" + name}
	if !v.IsFile(in.path) {
		fmt.Fprintf(errw, "verify-tool-catalog: ERROR — cannot find %s (absent-input)\n", in.path)
		return in, false
	}
	b, err := v.Read(in.path)
	if err != nil {
		fmt.Fprintf(errw, "verify-tool-catalog: ERROR — cannot read %s: %v (unreadable-input)\n", in.path, err)
		return in, false
	}
	in.text = string(b)
	return in, true
}

// check compares the tools logged in INSTALLED-TOOLS.md with tool-registry.md and writes the report. It returns the
// exit code: 0 for a clean run or advisory findings, 1 when an input is missing or unreadable.
func check(v fsview.View, dir string, l locale, out, errw io.Writer) int {
	installed, ok := readInput(v, dir, installedFile, errw)
	if !ok {
		return cli.ExitOperational
	}
	registry, ok := readInput(v, dir, registryFile, errw)
	if !ok {
		return cli.ExitOperational
	}
	tools := l.toolNames(installed.text)
	if len(tools) == 0 { // ANTI-SILENT-ZERO: a log with no tool in either form is not a sweep of zero tools
		fmt.Fprintln(out, "verify-tool-catalog: INSTALLED-TOOLS.md has no tool log rows (empty-input) — nothing to reconcile.")
		return cli.ExitOK
	}
	lines := strings.Split(registry.text, "\n")
	var missing []string
	for _, tool := range tools {
		if !l.inRegistry(lines, tool) {
			missing = append(missing, tool)
			fmt.Fprintf(out, warnFmt+"\n", tool)
		}
	}
	fmt.Fprintln(out)
	fmt.Fprintf(out, summaryFmt+"\n", len(tools), len(tools)-len(missing), len(missing))
	if len(missing) == 0 {
		fmt.Fprintln(out, "Tool catalog consistent with INSTALLED-TOOLS.md (no-match: every logged tool is cataloged).")
	} else {
		fmt.Fprintf(out, gapFmt+"\n", strings.Join(missing, ", "))
	}
	return cli.ExitOK
}
