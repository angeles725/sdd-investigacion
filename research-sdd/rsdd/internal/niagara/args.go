package niagara

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// This file reproduces the argparse parser of the legacy Niagara scripts for a small option set: value-taking
// long options, -h/--help and at most one positional argument. It keeps the behaviours callers can trip over:
// unique-prefix abbreviations (--inp), --opt=value, a later duplicate overriding an earlier one, "--" turning the
// rest into positionals, "-hX" printing the help, and the error precedence (a missing required argument is
// reported before unrecognised arguments). Reference: CPython 3.15 argparse, COLUMNS=80. One version-dependent
// argparse corner is not reproduced: help wrapping under a narrower terminal.

// optDef is one value-taking long option.
type optDef struct {
	name     string // "--input"
	required bool
}

// argSpec describes one command line: its program name, the usage and help texts argparse renders, the long
// options in registration order and, when positional is not empty, the metavar of the one positional argument
// (which argparse registers first, so its missing-argument name comes first too).
type argSpec struct {
	prog       string
	usage      string // "usage: ...\n"
	help       string // the full -h output, usage included
	positional string
	opts       []optDef
}

// parsed is the outcome of a successful parse.
type parsed struct {
	input, output string // bog-nav's --input and --output
}

// parsedArgs is the outcome of a successful parse of an argSpec: the value of each option that was given and the
// positional (empty when the spec has none). An option given with an empty value is present with "".
type parsedArgs struct {
	vals       map[string]string
	positional string
}

// stop ends the run before any file is touched: help (exit 0) or a usage error (exit 2).
type stop struct {
	code int
	out  string
	err  string
}

func (sp argSpec) usageError(msg string) *stop {
	return &stop{code: 2, err: sp.usage + sp.prog + ": error: " + msg + "\n"}
}

type option int

const (
	optNone option = -1 // an option string argparse does not know
	optHelp option = -2
)

// token is one classified command-line word.
type token struct {
	isOption    bool   // argparse's 'O'; false is a positional-like 'A'
	opt         option // an index into spec.opts, optHelp or optNone
	explicit    string
	hasExplicit bool
	ambiguous   []string
}

// looksNegative is argparse's _negative_number_matcher, re.match(r'-\.?\d', arg) in CPython 3.15 (a prefix test,
// with Unicode digits like Python's \d). Older interpreters (<= 3.12) used '^-\d+$|^-\d*\.\d+$', which agrees
// on every plain number but treats forms such as "-5." and "-5x" as options.
func looksNegative(s string) bool {
	rest, ok := strings.CutPrefix(s, "-")
	if !ok {
		return false
	}
	rest = strings.TrimPrefix(rest, ".")
	r, _ := utf8.DecodeRuneInString(rest)
	return rest != "" && unicode.IsDigit(r)
}

// exact resolves an option string argparse knows exactly.
func (sp argSpec) exact(s string) option {
	if s == "-h" || s == "--help" {
		return optHelp
	}
	for i, o := range sp.opts {
		if o.name == s {
			return option(i)
		}
	}
	return optNone
}

// classify mirrors ArgumentParser._parse_optional for this parser's option set.
func (sp argSpec) classify(arg string) token {
	if arg == "" || arg[0] != '-' {
		return token{}
	}
	if o := sp.exact(arg); o != optNone {
		return token{isOption: true, opt: o}
	}
	if len(arg) == 1 {
		return token{}
	}
	if pre, val, ok := strings.Cut(arg, "="); ok {
		if o := sp.exact(pre); o != optNone {
			return token{isOption: true, opt: o, explicit: val, hasExplicit: true}
		}
	}
	if strings.HasPrefix(arg, "--") {
		pre, val, hasEq := strings.Cut(arg, "=")
		var hits []string
		var which option
		names := append([]string{"--help"}, optNames(sp.opts)...)
		for _, n := range names {
			if strings.HasPrefix(n, pre) {
				hits = append(hits, n)
				which = sp.exact(n)
			}
		}
		switch len(hits) {
		case 0:
		case 1:
			return token{isOption: true, opt: which, explicit: val, hasExplicit: hasEq}
		default:
			return token{isOption: true, ambiguous: hits}
		}
	} else if arg[1] == 'h' {
		// "-hX": the short help flag followed by anything. CPython 3.15 runs the help action first.
		return token{isOption: true, opt: optHelp}
	}
	if looksNegative(arg) || strings.Contains(arg, " ") {
		return token{}
	}
	return token{isOption: true, opt: optNone}
}

func optNames(opts []optDef) []string {
	names := make([]string, len(opts))
	for i, o := range opts {
		names[i] = o.name
	}
	return names
}

// parse parses args. A non-nil stop means the run ends there.
//
// Positionals follow argparse's pattern matching: the first positional-like word (or "--" plus the word after
// it) fills the positional; a "--" directly after that word is swallowed with it; every later word is extra.
func (sp argSpec) parse(args []string) (parsedArgs, *stop) {
	p := parsedArgs{vals: map[string]string{}}
	havePos := sp.positional == ""
	var extras []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			rest := args[i:]
			if !havePos && len(rest) > 1 {
				p.positional, havePos = rest[1], true
				rest = rest[2:]
			}
			extras = append(extras, rest...)
			break
		}
		tok := sp.classify(arg)
		if !tok.isOption {
			if !havePos {
				p.positional, havePos = arg, true
				if i+1 < len(args) && args[i+1] == "--" { // argparse's A- pattern takes the separator along
					extras = append(extras, args[i+2:]...)
					break
				}
				continue
			}
			extras = append(extras, arg)
			continue
		}
		if tok.ambiguous != nil {
			return p, sp.usageError(fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(tok.ambiguous, ", ")))
		}
		switch tok.opt {
		case optNone:
			extras = append(extras, arg)
		case optHelp:
			if tok.hasExplicit {
				return p, sp.usageError(fmt.Sprintf("argument -h/--help: ignored explicit argument %s", pyQuote(tok.explicit)))
			}
			return p, &stop{out: sp.help}
		default:
			name := sp.opts[tok.opt].name
			var val string
			switch {
			case tok.hasExplicit:
				val = tok.explicit
			case i+1 < len(args) && args[i+1] != "--" && !sp.classify(args[i+1]).isOption:
				i++
				val = args[i]
			default:
				return p, sp.usageError("argument " + name + ": expected one argument")
			}
			p.vals[name] = val
		}
	}
	var missing []string
	if !havePos {
		missing = append(missing, sp.positional)
	}
	for _, o := range sp.opts {
		if _, ok := p.vals[o.name]; o.required && !ok {
			missing = append(missing, o.name)
		}
	}
	if len(missing) > 0 {
		return p, sp.usageError("the following arguments are required: " + strings.Join(missing, ", "))
	}
	if len(extras) > 0 {
		return p, sp.usageError("unrecognized arguments: " + strings.Join(extras, " "))
	}
	return p, nil
}

// pyQuote is repr() for the short strings that appear in argparse messages.
func pyQuote(s string) string {
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		return `"` + s + `"`
	}
	return "'" + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), "'", `\'`) + "'"
}

// bog-nav: bog_nav.py --input BOG --output JSON.
const (
	progName  = "bog-nav"
	usageLine = "usage: bog-nav [-h] --input BOG --output JSON\n"
	helpText  = usageLine + "\nNiagara N4 config.bog structural evidence extractor.\n\noptions:\n" +
		"  -h, --help     show this help message and exit\n" +
		"  --input BOG    config.bog (ZIP-compressed file.xml) or bare XML file\n" +
		"  --output JSON  output JSON evidence file path (must not already exist)\n"
)

var bogNavSpec = argSpec{
	prog: progName, usage: usageLine, help: helpText,
	opts: []optDef{{"--input", true}, {"--output", true}},
}

func parseArgs(args []string) (parsed, *stop) {
	p, st := bogNavSpec.parse(args)
	if st != nil {
		return parsed{}, st
	}
	return parsed{input: p.vals["--input"], output: p.vals["--output"]}, nil
}
