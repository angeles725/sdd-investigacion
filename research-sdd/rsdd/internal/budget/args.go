package budget

import "strings"

// usageLine is the script's usage message, kept verbatim so a shim caller sees the same bytes.
const usageLine = "usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>"

// options is the parsed command line.
type options struct {
	harness  string // claude (default) | pi | both
	target   string // as given; resolved by the caller
	toolbelt string // directory of the shim that called us ("" = resolve the kit)
}

// parseArgs reads [--toolbelt DIR] [--harness claude|pi|both] <target-dir>. The leading --toolbelt is the shim's
// own directory (the binary cannot see the script's location); everything after it is the script's contract:
// --harness only as the FIRST argument, then exactly one target. ok is false for a usage error.
func parseArgs(args []string) (o options, ok bool) {
	o.harness = "claude"
	if len(args) >= 2 && args[0] == "--toolbelt" {
		o.toolbelt = args[1]
		args = args[2:]
	} else if len(args) >= 1 && strings.HasPrefix(args[0], "--toolbelt=") {
		o.toolbelt = strings.TrimPrefix(args[0], "--toolbelt=")
		args = args[1:]
	}
	if len(args) > 0 && args[0] == "--harness" {
		v := ""
		if len(args) > 1 {
			v = args[1]
		}
		switch v {
		case "claude", "pi", "both":
			o.harness = v
		default:
			return o, false
		}
		args = args[2:]
	}
	if len(args) != 1 {
		return o, false
	}
	o.target = args[0]
	return o, true
}
