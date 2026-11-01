package corpus

import (
	"os"
	"path/filepath"
	"strings"
)

const archiveUsage = "usage: research-sdd-archive.sh <target-dir> [--focus <name>] [--dry-run] [--allow-unreciprocated-corrections]"

// archiveArgs is the parsed command line.
type archiveArgs struct {
	target    string
	dry       bool
	focus     string
	allowVC   bool
	toolbelt  string // --toolbelt DIR: the directory holding the sibling scripts (the shim passes its own)
	errLine   string // non-empty: print it on stderr and exit 2
	targetSet bool
}

// archiveParseArgs mirrors the argument loop of research-sdd-archive.sh, message for message. --toolbelt is the one
// addition: the compatibility shim passes the directory the script lived in.
func archiveParseArgs(args []string) archiveArgs {
	var a archiveArgs
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--dry-run":
			a.dry = true
		case arg == "--allow-unreciprocated-corrections":
			a.allowVC = true
		case arg == "--toolbelt":
			if i+1 >= len(args) || args[i+1] == "" {
				a.errLine = "research-sdd-archive: --toolbelt requires a directory"
				return a
			}
			a.toolbelt = strings.TrimSuffix(args[i+1], "/")
			i++
		case strings.HasPrefix(arg, "--toolbelt="):
			a.toolbelt = strings.TrimSuffix(strings.TrimPrefix(arg, "--toolbelt="), "/")
		case arg == "--focus":
			if i+1 >= len(args) || args[i+1] == "" {
				a.errLine = "research-sdd-archive: --focus requires a focus name"
				return a
			}
			a.focus = args[i+1]
			i++
		case strings.HasPrefix(arg, "-"):
			a.errLine = "research-sdd-archive: unknown flag: " + arg
			return a
		default:
			// `[ -z "$target" ] && target="$1" || error`: an empty first positional leaves the slot free.
			if a.target == "" {
				a.target = arg
			} else {
				a.errLine = "research-sdd-archive: unexpected extra arg: " + arg
				return a
			}
		}
	}
	return a
}

// archiveAbsTarget resolves the target the way `cd "$target" && pwd` does: relative to cwd, logically (symlinks kept,
// dots collapsed lexically). ok is false when the directory cannot be entered.
func archiveAbsTarget(cwd, target string) (string, bool) {
	p := target
	switch {
	case p == "":
		p = cwd
	case !filepath.IsAbs(p):
		p = filepath.Join(cwd, p)
	}
	p = filepath.Clean(p)
	st, err := os.Stat(p + "/.")
	if err != nil || !st.IsDir() {
		return "", false
	}
	return p, true
}

// archiveIsDir is `[ -d path ]` relative to cwd.
func archiveIsDir(cwd, path string) bool {
	if !filepath.IsAbs(path) {
		path = filepath.Join(cwd, path)
	}
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}
