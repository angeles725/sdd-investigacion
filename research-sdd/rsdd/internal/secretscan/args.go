package secretscan

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// scriptName prefixes the usage lines: the legacy script's name is part of its output contract.
const scriptName = "scan-secrets.sh"

const usageLine = "usage: " + scriptName + " [--committed | --files-from <list|->] <target-dir>"

// options are the parsed command-line arguments.
type options struct {
	target    string
	committed bool
	filesFrom string
	// toolbelt is the directory of the shim (it passes its own); its parent is the kit root that holds TARGETS.md.
	toolbelt string
}

// parseArgs reads args strictly: a flag is accepted anywhere before or after the one target, a repeated flag, an
// unknown word that looks like a flag and a second target are all exit-2 usage errors (the legacy script silently
// ignored a trailing --committed, which turned a history scan into a working-tree scan, and any extra word).
// ok is false when the run must stop with exit; the message is already written.
func parseArgs(args []string, s cli.Stdio) (o options, exit int, ok bool) {
	usageErr := func(format string, a ...any) (options, int, bool) {
		fmt.Fprintf(s.Err, scriptName+": "+format+"\n"+usageLine+"\n", a...)
		return o, cli.ExitUsage, false
	}
	seenFF, seenTB, optionsDone, haveTarget := false, false, false, false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case optionsDone || a == "" || a[0] != '-' || a == "-":
			if haveTarget {
				return usageErr("unexpected extra argument: %s", a)
			}
			o.target, haveTarget = a, true
		case a == "--":
			optionsDone = true
		case a == "--committed":
			if o.committed {
				return usageErr("--committed given twice")
			}
			o.committed = true
		case a == "--files-from":
			if seenFF {
				return usageErr("--files-from given twice")
			}
			seenFF = true
			if i+1 >= len(args) || args[i+1] == "" {
				fmt.Fprintln(s.Err, "usage: "+scriptName+" --files-from requires a list file (or - for stdin)")
				return o, cli.ExitUsage, false
			}
			i++
			o.filesFrom = args[i]
		case a == "--toolbelt":
			if seenTB || i+1 >= len(args) {
				return usageErr("--toolbelt needs exactly one directory")
			}
			seenTB = true
			i++
			o.toolbelt = args[i]
		default:
			return usageErr("unknown argument: %s", a)
		}
	}
	if !haveTarget || !isDir(o.target, s.Cwd) {
		fmt.Fprintln(s.Err, usageLine)
		return o, cli.ExitUsage, false
	}
	if o.filesFrom != "" && o.committed {
		fmt.Fprintln(s.Err, "usage: "+scriptName+" --files-from cannot be combined with --committed (history is not a file set)")
		return o, cli.ExitUsage, false
	}
	return o, 0, true
}

// isDir is `[ -n "$p" ] && [ -d "$p" ]` with a relative path taken against the caller's working directory.
func isDir(p, cwd string) bool {
	if p == "" {
		return false
	}
	if !filepath.IsAbs(p) && cwd != "" {
		p = filepath.Join(cwd, p)
	}
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
