package pcap

import (
	"fmt"
	"io"
	"math/big"
	"regexp"
	"strings"
)

// A small argparse: just the behaviour the two legacy tools had, so a caller's command line means the same
// thing and every usage error prints the same text (the program name stays the legacy script's). Supported:
// --name value, --name=value, unique prefixes of long options, -h/--help, "--", negative numbers as values,
// and argparse's error messages in argparse's order (an ambiguous prefix while classifying, then type errors
// as they are met, then missing required options, then unrecognized arguments).

const (
	kindHelp = iota
	kindPath
	kindInt
)

type option struct {
	name string // "--input"
	dest string
	kind int
}

var helpOption = &option{name: "--help", kind: kindHelp}

// cmdline describes one command's arguments.
type cmdline struct {
	prog     string
	usage    string // the "usage: ..." block, newline-terminated
	help     string // usage, blank line, options
	options  []option
	required []string // dests, in definition order
}

// parsedArgs holds the values by dest: strings for paths, big integers for ints.
type parsedArgs struct {
	str map[string]string
	num map[string]*big.Int
}

var negativeNumber = regexp.MustCompile(`^-[0-9]+$|^-[0-9]*\.[0-9]+$`)

// usageError is argparse's error(): the usage block, then "<prog>: error: <message>", exit status 2.
func (c cmdline) usageError(w io.Writer, msg string) int {
	fmt.Fprint(w, c.usage)
	fmt.Fprintf(w, "%s: error: %s\n", c.prog, msg)
	return 2
}

func (c cmdline) lookup(name string) *option {
	if name == "-h" || name == "--help" {
		return helpOption
	}
	for i := range c.options {
		if c.options[i].name == name {
			return &c.options[i]
		}
	}
	return nil
}

// optionStrings lists the option strings in registration order: -h and --help first, as argparse does.
func (c cmdline) optionStrings() []string {
	names := []string{"-h", "--help"}
	for _, o := range c.options {
		names = append(names, o.name)
	}
	return names
}

// classified is argparse's _parse_optional for one token.
type classified struct {
	value    bool    // a plain value ("A")
	opt      *option // nil on an unknown option-looking token
	explicit *string // text glued to the option (--name=value, -hX)
	sep      bool    // the glue was "="
	err      string  // an ambiguous prefix
}

func (c cmdline) classify(arg string) classified {
	if arg == "" || arg[0] != '-' {
		return classified{value: true}
	}
	if o := c.lookup(arg); o != nil {
		return classified{opt: o}
	}
	if len(arg) == 1 {
		return classified{value: true}
	}
	if name, val, ok := strings.Cut(arg, "="); ok {
		if o := c.lookup(name); o != nil {
			return classified{opt: o, explicit: &val, sep: true}
		}
	}
	if strings.HasPrefix(arg, "--") {
		prefix, val, hasVal := strings.Cut(arg, "=")
		var matches []string
		for _, n := range c.optionStrings() {
			if strings.HasPrefix(n, "--") && strings.HasPrefix(n, prefix) {
				matches = append(matches, n)
			}
		}
		if len(matches) > 1 {
			return classified{err: fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(matches, ", "))}
		}
		if len(matches) == 1 {
			cl := classified{opt: c.lookup(matches[0])}
			if hasVal {
				cl.explicit, cl.sep = &val, true
			}
			return cl
		}
	} else if arg[1] == 'h' {
		rest := arg[2:]
		return classified{opt: helpOption, explicit: &rest}
	}
	if negativeNumber.MatchString(arg) || strings.Contains(arg, " ") {
		return classified{value: true}
	}
	return classified{}
}

// parse reads args. When done is true the caller returns code (help printed or an error reported).
func (c cmdline) parse(args []string, out, errw io.Writer) (p parsedArgs, code int, done bool) {
	p = parsedArgs{str: map[string]string{}, num: map[string]*big.Int{}}
	const (
		isValue = 'A'
		isOpt   = 'O'
		isDash  = '-'
	)
	pattern := make([]byte, len(args))
	cls := make([]classified, len(args))
	afterDashes := false
	for i, a := range args {
		switch {
		case afterDashes:
			pattern[i] = isValue
		case a == "--":
			pattern[i], afterDashes = isDash, true
		default:
			cls[i] = c.classify(a)
			if cls[i].err != "" {
				return p, c.usageError(errw, cls[i].err), true
			}
			pattern[i] = isOpt
			if cls[i].value {
				pattern[i] = isValue
			}
		}
	}
	var extras []string
	seen := map[string]bool{}
	for i := 0; i < len(args); {
		cl := cls[i]
		if pattern[i] != isOpt || cl.opt == nil {
			extras = append(extras, args[i])
			i++
			continue
		}
		o := cl.opt
		if o.kind == kindHelp {
			if msg, bad := helpGlued(args[i], cl); bad {
				return p, c.usageError(errw, msg), true
			}
			fmt.Fprint(out, c.help)
			return p, 0, true
		}
		var value string
		if cl.explicit != nil {
			value = *cl.explicit
			i++
		} else {
			// An option's value is the very next token: argparse drops the "--" allowance for optionals.
			if i+1 >= len(args) || pattern[i+1] != isValue {
				return p, c.usageError(errw, "argument "+o.name+": expected one argument"), true
			}
			value = args[i+1]
			i += 2
		}
		if o.kind == kindInt {
			n, ok := parseInt(pyStrip(value))
			if !ok {
				return p, c.usageError(errw, "argument "+o.name+": invalid int value: "+pyRepr(value)), true
			}
			p.num[o.dest] = n
		} else {
			p.str[o.dest] = value
		}
		seen[o.dest] = true
	}
	var missing []string
	for _, d := range c.required {
		if !seen[d] {
			missing = append(missing, "--"+strings.ReplaceAll(d, "_", "-"))
		}
	}
	if len(missing) > 0 {
		return p, c.usageError(errw, "the following arguments are required: "+strings.Join(missing, ", ")), true
	}
	if len(extras) > 0 {
		return p, c.usageError(errw, "unrecognized arguments: "+strings.Join(extras, " ")), true
	}
	return p, 0, false
}

// helpGlued is the check argparse makes when -h/--help carries glued text. "--help=x" and "-h=x" are refused;
// "-hX" is -h followed by the short option -X, which argparse only collects as an unrecognized argument after
// running help, so the help still prints; "-h-x" is refused. Further glued letters are read the same way.
func helpGlued(arg string, cl classified) (string, bool) {
	if cl.explicit == nil {
		return "", false
	}
	const prefix = "argument -h/--help: ignored explicit argument "
	if strings.HasPrefix(arg, "--") {
		return prefix + pyRepr(*cl.explicit), true
	}
	e, sep := *cl.explicit, cl.sep
	for {
		if e == "" && !sep {
			return "", false
		}
		if sep || e[0] == '-' {
			return prefix + pyRepr(e), true
		}
		if e[0] != 'h' {
			return "", false
		}
		rest := e[1:]
		switch {
		case rest == "":
			return "", false
		case rest[0] == '=':
			sep, e = true, rest[1:]
		default:
			e = rest
		}
	}
}
