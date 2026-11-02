package adapter

import (
	"fmt"
	"strings"
)

// The command line of analysis_manifest.py, as its callers use it:
//
//	create --root ROOT --spec SPEC --output OUTPUT [--overwrite]   (options in any order)
//	validate MANIFEST
//	verify --root ROOT MANIFEST
//
// Not carried over from argparse: abbreviated options, --opt=value, "--", option values that look
// like options, bundled short options, the "maybe you meant" hint and COLUMNS-dependent layout.
// A command line outside the forms above is a usage error (exit 2) and -h/--help prints the usage.

const usageText = "usage: analysis_manifest.py {create,validate,verify} ...\n" +
	"  create --root ROOT --spec SPEC --output OUTPUT [--overwrite]\n" +
	"  validate MANIFEST\n" +
	"  verify --root ROOT MANIFEST\n"

// commandOptions is each command and the options it requires.
var commandOptions = map[string][]string{"create": {"--root", "--spec", "--output"}, "validate": {}, "verify": {"--root"}}

type parsed struct {
	command                      string
	root, spec, output, manifest string
	overwrite                    bool
}

// parseArgs returns the parsed command line, or help=true for -h/--help, or a usage error.
func parseArgs(args []string) (ns parsed, help bool, err error) {
	if len(args) == 0 {
		return ns, false, fmt.Errorf("the following arguments are required: command")
	}
	if args[0] == "-h" || args[0] == "--help" {
		return ns, true, nil
	}
	ns.command = args[0]
	options := map[string]*string{"--root": &ns.root, "--spec": &ns.spec, "--output": &ns.output}
	allowed, known := commandOptions[ns.command]
	if !known {
		return ns, false, fmt.Errorf("argument command: invalid choice: %s (choose from 'create', 'validate', 'verify')", pyRepr(ns.command))
	}
	given := map[string]bool{}
	var positional []string
	rest := args[1:]
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		switch {
		case a == "--help" || a == "-h":
			return ns, true, nil
		case a == "--overwrite" && ns.command == "create":
			ns.overwrite = true
		case options[a] != nil && contains(allowed, a):
			if i+1 == len(rest) {
				return ns, false, fmt.Errorf("argument %s: expected one argument", a)
			}
			i++
			*options[a] = pyNorm(rest[i])
			given[a] = true
		case strings.HasPrefix(a, "-") && a != "-":
			return ns, false, fmt.Errorf("unrecognized arguments: %s", a)
		default:
			positional = append(positional, a)
		}
	}
	var missing []string
	for _, o := range allowed {
		if !given[o] {
			missing = append(missing, o)
		}
	}
	wantPositional := 0
	if ns.command != "create" {
		wantPositional = 1
		if len(positional) == 0 {
			missing = append(missing, "manifest")
		}
	}
	if len(missing) > 0 {
		return ns, false, fmt.Errorf("the following arguments are required: %s", strings.Join(missing, ", "))
	}
	if len(positional) > wantPositional {
		return ns, false, fmt.Errorf("unrecognized arguments: %s", strings.Join(positional[wantPositional:], " "))
	}
	if wantPositional == 1 {
		ns.manifest = pyNorm(positional[0])
	}
	return ns, false, nil
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}
