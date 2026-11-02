package capa

// argparse emulation for the legacy tool's parser (Python 3.12): option abbreviation, "--opt=value",
// negative-number values, "--" handling and the exact error messages. The parser has no positionals, so
// every argument that is not consumed by an option is an "unrecognized argument".

import (
	"errors"
	"fmt"
	"math/big"
	"strings"
	"unicode"
)

// Defaults of the legacy parser.
const (
	defaultRules   = "~/.local/share/capa-rules"
	defaultTimeout = 300
	defaultMaxCaps = 500
)

// options is the parsed command line. Path-typed values are kept as str(Path(arg)).
type options struct {
	input, output, rules, manifestCLI string
	timeout, maxCapabilities          *big.Int
}

// optSpec is one registered option; the order is the parser's registration order (it decides the
// order of ambiguity and "required" messages).
type optSpec struct {
	name     string // "--input"
	help     bool   // the help action: takes no value
	required bool
}

var optSpecs = []optSpec{
	{name: "-h", help: true}, {name: "--help", help: true},
	{name: "--input", required: true}, {name: "--output", required: true}, {name: "--rules"},
	{name: "--timeout"}, {name: "--max-capabilities"}, {name: "--manifest-cli", required: true},
}

func findSpec(name string) (int, bool) {
	for i, o := range optSpecs {
		if o.name == name {
			return i, true
		}
	}
	return -1, false
}

// argKind is argparse's option-string pattern letter.
type argKind byte

const (
	kindArg  argKind = 'A' // a value or an extra
	kindOpt  argKind = 'O' // an option (spec index in classified.spec, -1 when unknown)
	kindDash argKind = '-' // the "--" separator
)

type classified struct {
	kind     argKind
	spec     int // index into optSpecs; -1 for an unknown option
	explicit *string
	sep      bool // the explicit value came after "="
}

// argError is a usage error: usage + "corroborate-capa: error: <msg>" on stderr, exit 2.
type argError struct{ msg string }

func (e *argError) Error() string { return e.msg }

var negativeNumber = func(s string) bool {
	// '^-\d+$|^-\d*\.\d+$'
	if len(s) < 2 || s[0] != '-' {
		return false
	}
	body := s[1:]
	digits := func(t string) bool {
		for _, r := range t {
			if r < '0' || r > '9' {
				return false
			}
		}
		return true
	}
	if i := strings.IndexByte(body, '.'); i >= 0 {
		return digits(body[:i]) && body[i+1:] != "" && digits(body[i+1:])
	}
	return body != "" && digits(body)
}

// classify is ArgumentParser._parse_optional.
func classify(arg string) (classified, error) {
	if arg == "" || arg[0] != '-' {
		return classified{kind: kindArg}, nil
	}
	if i, ok := findSpec(arg); ok {
		return classified{kind: kindOpt, spec: i}, nil
	}
	if len(arg) == 1 {
		return classified{kind: kindArg}, nil
	}
	if name, val, ok := strings.Cut(arg, "="); ok {
		if i, found := findSpec(name); found {
			return classified{kind: kindOpt, spec: i, explicit: &val, sep: true}, nil
		}
	}
	var matches []int
	var explicit *string
	sep := false
	switch {
	case strings.HasPrefix(arg, "--"):
		prefix := arg
		if name, val, ok := strings.Cut(arg, "="); ok {
			prefix = name
			explicit = &val
			sep = true
		}
		for i, o := range optSpecs {
			if strings.HasPrefix(o.name, prefix) {
				matches = append(matches, i)
			}
		}
	default: // a single dash and a letter: short-option cluster
		short, rest := arg[:2], arg[2:]
		for i, o := range optSpecs {
			if o.name == short {
				matches = append(matches, i)
				explicit = &rest
			} else if strings.HasPrefix(o.name, arg) {
				matches = append(matches, i)
			}
		}
	}
	switch len(matches) {
	case 0:
	case 1:
		return classified{kind: kindOpt, spec: matches[0], explicit: explicit, sep: sep}, nil
	default:
		names := make([]string, len(matches))
		for i, m := range matches {
			names[i] = optSpecs[m].name
		}
		return classified{}, &argError{fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(names, ", "))}
	}
	if negativeNumber(arg) || strings.Contains(arg, " ") {
		return classified{kind: kindArg}, nil
	}
	return classified{kind: kindOpt, spec: -1}, nil
}

// decimalValue is the value (0-9) of a Unicode decimal digit: its offset in its block of ten.
func decimalValue(r rune) rune {
	start := r
	for unicode.IsDigit(start - 1) {
		start--
	}
	return (r - start) % 10
}

// pyIntMaxDigits is CPython's int/str conversion limit.
const pyIntMaxDigits = 4300

// parsePyInt is int(str): surrounding whitespace, a sign, ASCII digits with single underscores between them.
func parsePyInt(s string) (*big.Int, bool) {
	t := strings.TrimFunc(s, func(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) })
	neg := false
	if t != "" && (t[0] == '+' || t[0] == '-') {
		neg = t[0] == '-'
		t = t[1:]
	}
	if t == "" || t[0] == '_' || t[len(t)-1] == '_' {
		return nil, false
	}
	var digits strings.Builder
	prevUnderscore := false
	for _, r := range t {
		switch {
		case unicode.IsDigit(r):
			digits.WriteRune('0' + decimalValue(r))
			prevUnderscore = false
		case r == '_' && !prevUnderscore:
			prevUnderscore = true
		default:
			return nil, false
		}
	}
	if digits.Len() > pyIntMaxDigits {
		return nil, false
	}
	n, ok := new(big.Int).SetString(digits.String(), 10)
	if !ok {
		return nil, false
	}
	if neg {
		n.Neg(n)
	}
	return n, true
}

// errHelp reports that -h/--help was consumed: the caller prints the help text and exits 0.
var errHelp = errors.New("help requested")

// parseArgs is parse_args for the legacy parser. It returns errHelp for a consumed help action and an
// *argError for every usage error.
func parseArgs(args []string) (options, error) {
	opts := options{rules: pyNorm(defaultRules), timeout: big.NewInt(defaultTimeout), maxCapabilities: big.NewInt(defaultMaxCaps)}
	// 1. classify every argument (an ambiguous abbreviation fails here, before anything is consumed).
	cls := make([]classified, len(args))
	afterDash := false
	for i, a := range args {
		switch {
		case afterDash:
			cls[i] = classified{kind: kindArg}
		case a == "--":
			cls[i] = classified{kind: kindDash}
			afterDash = true
		default:
			c, err := classify(a)
			if err != nil {
				return opts, err
			}
			cls[i] = c
		}
	}
	// 2. consume options in order; everything else is an extra.
	seen := map[int]bool{}
	var extras []string
	for i := 0; i < len(args); {
		c := cls[i]
		if c.kind != kindOpt {
			extras = append(extras, args[i])
			i++
			continue
		}
		if c.spec < 0 {
			extras = append(extras, args[i])
			i++
			continue
		}
		spec := optSpecs[c.spec]
		if spec.help {
			if c.sep {
				return opts, &argError{fmt.Sprintf("argument -h/--help: ignored explicit argument %s", pyRepr(*c.explicit))}
			}
			return opts, errHelp
		}
		var value string
		switch {
		case c.explicit != nil:
			value = *c.explicit
			i++
		case i+1 < len(args) && cls[i+1].kind == kindArg:
			value = args[i+1]
			i += 2
		default:
			return opts, &argError{fmt.Sprintf("argument %s: expected one argument", spec.name)}
		}
		seen[c.spec] = true
		switch spec.name {
		case "--input":
			opts.input = pyNorm(value)
		case "--output":
			opts.output = pyNorm(value)
		case "--rules":
			opts.rules = pyNorm(value)
		case "--manifest-cli":
			opts.manifestCLI = pyNorm(value)
		case "--timeout", "--max-capabilities":
			n, ok := parsePyInt(value)
			if !ok {
				return opts, &argError{fmt.Sprintf("argument %s: invalid int value: %s", spec.name, pyRepr(value))}
			}
			if spec.name == "--timeout" {
				opts.timeout = n
			} else {
				opts.maxCapabilities = n
			}
		}
	}
	var missing []string
	for i, o := range optSpecs {
		if o.required && !seen[i] {
			missing = append(missing, o.name)
		}
	}
	if len(missing) > 0 {
		return opts, &argError{"the following arguments are required: " + strings.Join(missing, ", ")}
	}
	if len(extras) > 0 {
		return opts, &argError{"unrecognized arguments: " + strings.Join(extras, " ")}
	}
	return opts, nil
}
