package niagara

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// This file reproduces the argparse parser of the legacy bog_nav.py for its three options (-h/--help, --input,
// --output), including the behaviours callers can trip over: unique-prefix abbreviations (--inp), --opt=value,
// a later duplicate overriding an earlier one, "--" turning the rest into positionals, and the error precedence
// (a missing required option is reported before unrecognised arguments). Reference: CPython 3.15 argparse,
// COLUMNS=80. Two version-dependent argparse corners are not reproduced: the combined short form "-hX" and help
// wrapping under a narrower terminal.

const (
	progName  = "bog-nav"
	usageLine = "usage: bog-nav [-h] --input BOG --output JSON\n"
	helpText  = usageLine + "\nNiagara N4 config.bog structural evidence extractor.\n\noptions:\n" +
		"  -h, --help     show this help message and exit\n" +
		"  --input BOG    config.bog (ZIP-compressed file.xml) or bare XML file\n" +
		"  --output JSON  output JSON evidence file path (must not already exist)\n"
)

type option int

const (
	optNone option = iota
	optHelp
	optInput
	optOutput
)

// longOptions are the long option strings in argparse's registration order (the order ambiguity errors list).
var longOptions = []struct {
	name string
	opt  option
}{{"--help", optHelp}, {"--input", optInput}, {"--output", optOutput}}

// parsed is the outcome of a successful parse.
type parsed struct{ input, output string }

// stop ends the run before any file is touched: help (exit 0) or a usage error (exit 2).
type stop struct {
	code int
	out  string
	err  string
}

func usageError(msg string) *stop {
	return &stop{code: 2, err: usageLine + progName + ": error: " + msg + "\n"}
}

// token is one classified command-line word.
type token struct {
	isOption    bool   // argparse's 'O'; false is a positional-like 'A'
	opt         option // optNone for an unknown option
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

// classify mirrors ArgumentParser._parse_optional for this parser's option set.
func classify(arg string) token {
	if arg == "" || arg[0] != '-' {
		return token{}
	}
	exact := func(s string) option {
		switch s {
		case "-h", "--help":
			return optHelp
		case "--input":
			return optInput
		case "--output":
			return optOutput
		}
		return optNone
	}
	if o := exact(arg); o != optNone {
		return token{isOption: true, opt: o}
	}
	if len(arg) == 1 {
		return token{}
	}
	if pre, val, ok := strings.Cut(arg, "="); ok {
		if o := exact(pre); o != optNone {
			return token{isOption: true, opt: o, explicit: val, hasExplicit: true}
		}
	}
	if strings.HasPrefix(arg, "--") {
		pre, val, hasEq := strings.Cut(arg, "=")
		var hits []string
		var which option
		for _, lo := range longOptions {
			if strings.HasPrefix(lo.name, pre) {
				hits = append(hits, lo.name)
				which = lo.opt
			}
		}
		switch len(hits) {
		case 0:
		case 1:
			return token{isOption: true, opt: which, explicit: val, hasExplicit: hasEq}
		default:
			return token{isOption: true, ambiguous: hits}
		}
	}
	if looksNegative(arg) || strings.Contains(arg, " ") {
		return token{}
	}
	return token{isOption: true}
}

// parseArgs parses args. A non-nil stop means the run ends there.
func parseArgs(args []string) (parsed, *stop) {
	var p parsed
	var haveIn, haveOut bool
	var extras []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			extras = append(extras, args[i:]...)
			break
		}
		tok := classify(arg)
		if !tok.isOption {
			extras = append(extras, arg)
			continue
		}
		if tok.ambiguous != nil {
			return p, usageError(fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(tok.ambiguous, ", ")))
		}
		switch tok.opt {
		case optNone:
			extras = append(extras, arg)
		case optHelp:
			if tok.hasExplicit {
				return p, usageError(fmt.Sprintf("argument -h/--help: ignored explicit argument %s", pyQuote(tok.explicit)))
			}
			return p, &stop{out: helpText}
		case optInput, optOutput:
			name := "--input"
			if tok.opt == optOutput {
				name = "--output"
			}
			var val string
			switch {
			case tok.hasExplicit:
				val = tok.explicit
			case i+1 < len(args) && args[i+1] != "--" && !classify(args[i+1]).isOption:
				i++
				val = args[i]
			default:
				return p, usageError("argument " + name + ": expected one argument")
			}
			if tok.opt == optInput {
				p.input, haveIn = val, true
			} else {
				p.output, haveOut = val, true
			}
		}
	}
	var missing []string
	if !haveIn {
		missing = append(missing, "--input")
	}
	if !haveOut {
		missing = append(missing, "--output")
	}
	if len(missing) > 0 {
		return p, usageError("the following arguments are required: " + strings.Join(missing, ", "))
	}
	if len(extras) > 0 {
		return p, usageError("unrecognized arguments: " + strings.Join(extras, " "))
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
