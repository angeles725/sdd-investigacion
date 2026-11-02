package floss

import (
	"fmt"
	"io"
	"math/big"
	"regexp"
	"strings"
	"unicode"
)

// The command line of corroborate_floss.py, parsed the way Python 3.12's argparse parses it: long options may
// be abbreviated to a unique prefix, take --opt=value, "--" ends the options, a value may look like a negative
// number, -h/--help wins over later errors, and every refusal prints the usage and exits 2. The usage and help
// layout follow COLUMNS like argparse's HelpFormatter (width = columns - 2).
//
// Not carried over: an explicit "--opt=--" value (argparse drops the "--" and stores an empty list, which the
// script then crashes on); the port keeps the text "--".

const prog = "corroborate-floss"

type optKind int

const (
	kindHelp optKind = iota
	kindString
	kindInt
)

type optSpec struct {
	flags   []string // -h, --help
	metavar string
	help    string // "" = suppressed
	kind    optKind
	require bool
	dest    string
}

// specs is the parser definition, in argparse's order (it fixes the "required" and "ambiguous" listings).
var specs = []optSpec{
	{flags: []string{"-h", "--help"}, help: "show this help message and exit", kind: kindHelp},
	{flags: []string{"--input"}, metavar: "INPUT", help: "PE/ELF binary to analyse", kind: kindString, require: true, dest: "input"},
	{flags: []string{"--output"}, metavar: "OUTPUT", help: "New output directory (must not exist)", kind: kindString, require: true, dest: "output"},
	{flags: []string{"--timeout"}, metavar: "TIMEOUT", help: "Wall-clock timeout for floss (seconds, default 120)", kind: kindInt, dest: "timeout"},
	{flags: []string{"--max-strings"}, metavar: "MAX_STRINGS", help: "Maximum total strings sampled across all categories (default 2000)", kind: kindInt, dest: "max_strings"},
	{flags: []string{"--max-string-len"}, metavar: "MAX_STRING_LEN", help: "Maximum length of each sampled string value (default 256)", kind: kindInt, dest: "max_string_len"},
	{flags: []string{"--manifest-cli"}, metavar: "MANIFEST_CLI", kind: kindString, require: true, dest: "manifest_cli"},
}

// options are the parsed values. The integers keep Python's unbounded range.
type options struct {
	input, output, manifestCLI        string
	timeout, maxStrings, maxStringLen *big.Int
}

func (s optSpec) name() string { return strings.Join(s.flags, "/") }

type argError struct{ msg string }

func (e *argError) Error() string { return e.msg }

func argErr(s *optSpec, format string, v ...any) error {
	msg := fmt.Sprintf(format, v...)
	if s == nil {
		return &argError{msg}
	}
	return &argError{"argument " + s.name() + ": " + msg}
}

// optionIndex maps every option string to its spec index, in definition order.
func optionStrings() (names []string, owner []int) {
	for i, s := range specs {
		for _, f := range s.flags {
			names = append(names, f)
			owner = append(owner, i)
		}
	}
	return names, owner
}

// optTuple is argparse's (action, option_string, sep, explicit_arg); eq is "sep is =" (the other separator,
// the empty one of a bundled short option, is falsy like None).
type optTuple struct {
	spec     int // -1: unknown option
	option   string
	explicit *string
	eq       bool
}

var negativeNumber = regexp.MustCompile(`^-[0-9]+$|^-[0-9]*\.[0-9]+$`)

// classify is _parse_optional: nil for a positional, otherwise the option it names.
func classify(arg string) (*optTuple, error) {
	names, owner := optionStrings()
	if arg == "" || arg[0] != '-' {
		return nil, nil
	}
	for k, n := range names {
		if arg == n {
			return &optTuple{spec: owner[k], option: n}, nil
		}
	}
	if len(arg) == 1 {
		return nil, nil
	}
	if before, after, ok := strings.Cut(arg, "="); ok {
		for k, n := range names {
			if before == n {
				v := after
				return &optTuple{spec: owner[k], option: n, explicit: &v, eq: true}, nil
			}
		}
	}
	var tuples []optTuple
	if arg[1] == '-' {
		prefix, explicit, eq := arg, (*string)(nil), false
		if before, after, ok := strings.Cut(arg, "="); ok {
			prefix, explicit, eq = before, &after, true
		}
		for k, n := range names {
			if strings.HasPrefix(n, prefix) {
				tuples = append(tuples, optTuple{owner[k], n, explicit, eq})
			}
		}
	} else {
		short, rest := arg[:2], arg[2:]
		for k, n := range names {
			if n == short {
				r := rest
				tuples = append(tuples, optTuple{owner[k], n, &r, false})
			} else if strings.HasPrefix(n, arg) {
				tuples = append(tuples, optTuple{owner[k], n, nil, false})
			}
		}
	}
	switch {
	case len(tuples) > 1:
		var m []string
		for _, t := range tuples {
			m = append(m, t.option)
		}
		return nil, argErr(nil, "ambiguous option: %s could match %s", arg, strings.Join(m, ", "))
	case len(tuples) == 1:
		return &tuples[0], nil
	}
	if negativeNumber.MatchString(arg) || strings.Contains(arg, " ") {
		return nil, nil
	}
	return &optTuple{spec: -1, option: arg}, nil
}

// parseArgs parses args; width is the help column limit (COLUMNS - 2). done reports that the command must
// stop with code (help printed on out, or a usage error printed on errw).
func parseArgs(args []string, width int, out, errw io.Writer) (opts options, code int, done bool) {
	fail := func(err error) (options, int, bool) {
		_, _ = io.WriteString(errw, formatUsage(width))
		_, _ = fmt.Fprintf(errw, "%s: error: %s\n", prog, err.Error())
		return opts, 2, true
	}
	kinds := make([]byte, len(args)) // 'A' positional, 'O' option, '-' the "--" separator
	tuples := make([]*optTuple, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--" {
			kinds[i] = '-'
			for i++; i < len(args); i++ {
				kinds[i] = 'A'
			}
			break
		}
		t, err := classify(args[i])
		if err != nil {
			return fail(err)
		}
		if t == nil {
			kinds[i] = 'A'
		} else {
			kinds[i], tuples[i] = 'O', t
		}
	}
	seen := map[int]bool{}
	var extras []string
	vals := map[string]string{}
	ints := map[string]*big.Int{}
	for i := 0; i < len(args); {
		if kinds[i] != 'O' {
			extras = append(extras, args[i])
			i++
			continue
		}
		t := tuples[i]
		if t.spec < 0 {
			extras = append(extras, args[i])
			i++
			continue
		}
		next, err := consume(args, kinds, i, *t, seen, vals, ints, width, out)
		if err != nil {
			return fail(err)
		}
		if next == helpPrinted {
			return opts, 0, true // help printed
		}
		i = next
	}
	var missing []string
	for k, s := range specs {
		if s.require && !seen[k] {
			missing = append(missing, s.flags[0])
		}
	}
	if len(missing) > 0 {
		return fail(argErr(nil, "the following arguments are required: %s", strings.Join(missing, ", ")))
	}
	if len(extras) > 0 {
		return fail(argErr(nil, "unrecognized arguments: %s", strings.Join(extras, " ")))
	}
	opts = options{input: pyPath(vals["input"]), output: pyPath(vals["output"]), manifestCLI: pyPath(vals["manifest_cli"]),
		timeout: ints["timeout"], maxStrings: ints["max_strings"], maxStringLen: ints["max_string_len"]}
	if opts.timeout == nil {
		opts.timeout = big.NewInt(120)
	}
	if opts.maxStrings == nil {
		opts.maxStrings = big.NewInt(2000)
	}
	if opts.maxStringLen == nil {
		opts.maxStringLen = big.NewInt(256)
	}
	return opts, 0, false
}

// Sentinels: consume returns helpPrinted after the help was printed; noSuchFlag is "no spec matches".
const (
	helpPrinted = -1
	noSuchFlag  = -1
)

// consume is consume_optional for the option at index i. It returns the next index to read, or helpPrinted
// after the help was printed.
func consume(args []string, kinds []byte, i int, t optTuple, seen map[int]bool, vals map[string]string, ints map[string]*big.Int, width int, out io.Writer) (int, error) {
	type action struct {
		spec int
		arg  []string
	}
	var actions []action
	cur := t
	stop := i + 1
loop:
	for {
		s := &specs[cur.spec]
		if cur.explicit == nil {
			if s.kind == kindHelp {
				actions = append(actions, action{cur.spec, nil})
			} else {
				if i+1 >= len(args) || kinds[i+1] != 'A' {
					return 0, argErr(s, "expected one argument")
				}
				actions = append(actions, action{cur.spec, []string{args[i+1]}})
				stop = i + 2
			}
			break
		}
		exp := *cur.explicit
		switch {
		case s.kind == kindHelp && cur.option[1] != '-' && exp != "":
			// A single-dash flag that takes nothing: the rest of the argument is more bundled flags (-hh).
			r := []rune(exp)
			if cur.eq || r[0] == '-' {
				return 0, argErr(s, "ignored explicit argument %s", pyRepr(exp))
			}
			actions = append(actions, action{cur.spec, nil})
			opt := "-" + string(r[0])
			next := noSuchFlag
			for k, sp := range specs {
				for _, f := range sp.flags {
					if f == opt {
						next = k
					}
				}
			}
			if next == noSuchFlag { // an unknown bundled flag is left over; the flags before it still run
				break loop
			}
			cur = optTuple{spec: next, option: opt}
			if rest := string(r[1:]); rest != "" {
				if rest[0] == '=' {
					cur.eq, rest = true, rest[1:]
				}
				cur.explicit = &rest
			}
		case s.kind != kindHelp:
			actions = append(actions, action{cur.spec, []string{exp}})
			break loop
		default:
			return 0, argErr(s, "ignored explicit argument %s", pyRepr(exp))
		}
	}
	for _, a := range actions {
		s := &specs[a.spec]
		seen[a.spec] = true
		switch s.kind {
		case kindHelp:
			_, _ = io.WriteString(out, formatHelp(width))
			return helpPrinted, nil
		case kindString:
			vals[s.dest] = a.arg[0]
		case kindInt:
			n, ok := parsePyInt(a.arg[0])
			if !ok {
				return 0, argErr(s, "invalid int value: %s", pyRepr(a.arg[0]))
			}
			ints[s.dest] = n
		}
	}
	return stop, nil
}

// maxIntDigits is Python 3.12's int(str) limit (sys.get_int_max_str_digits default).
const maxIntDigits = 4300

// parsePyInt is int(s) for base 10: surrounding white space, a sign, digits (any Unicode decimal digit) with
// single underscores between digits.
func parsePyInt(s string) (*big.Int, bool) {
	t := strings.TrimFunc(s, pySpace)
	neg := false
	if strings.HasPrefix(t, "+") || strings.HasPrefix(t, "-") {
		neg = t[0] == '-'
		t = t[1:]
	}
	if t == "" {
		return nil, false
	}
	var digits strings.Builder
	prevUnderscore, n := true, 0 // a leading underscore is invalid, like a doubled one
	for _, r := range t {
		switch {
		case r == '_':
			if prevUnderscore {
				return nil, false
			}
			prevUnderscore = true
		case unicode.Is(unicode.Nd, r):
			digits.WriteByte(byte('0' + decimalValue(r)))
			prevUnderscore = false
			n++
		default:
			return nil, false
		}
	}
	if prevUnderscore || n > maxIntDigits {
		return nil, false
	}
	v, ok := new(big.Int).SetString(digits.String(), 10)
	if !ok {
		return nil, false
	}
	if neg {
		v.Neg(v)
	}
	return v, true
}

// decimalValue is unicode.digit(r): Unicode decimal digits sit in runs of ten starting at the zero digit.
func decimalValue(r rune) int {
	start := r
	for unicode.Is(unicode.Nd, start-1) {
		start--
	}
	return int((r - start) % 10)
}

// ---------------------------------------------------------------- usage and help text

// usageParts are the usage fragments, in order (the manifest option is suppressed).
var usageParts = []string{"[-h]", "--input", "INPUT", "--output", "OUTPUT", "[--timeout TIMEOUT]", "[--max-strings MAX_STRINGS]", "[--max-string-len MAX_STRING_LEN]"}

// formatUsage is parser.format_usage() for a formatter of the given width.
func formatUsage(width int) string {
	const prefix = "usage: "
	textWidth := max(width, 11)
	getLines := func(parts []string, indent string, withPrefix bool) []string {
		var lines, cur []string
		var lineLen int
		if withPrefix {
			lineLen = len(prefix) - 1
		} else {
			lineLen = len(indent) - 1
		}
		for _, p := range parts {
			// argparse also requires a non-empty current line; the first part always fits here, so it is implied.
			if lineLen+1+len(p) > textWidth {
				lines = append(lines, indent+strings.Join(cur, " "))
				cur, lineLen = nil, len(indent)-1
			}
			cur = append(cur, p)
			lineLen += len(p) + 1
		}
		lines = append(lines, indent+strings.Join(cur, " ")) // parts is never empty, so cur is not either
		if withPrefix {
			lines[0] = lines[0][len(indent):]
		}
		return lines
	}
	var lines []string
	if float64(len(prefix)+len(prog)) <= 0.75*float64(textWidth) {
		indent := strings.Repeat(" ", len(prefix)+len(prog)+1)
		lines = getLines(append([]string{prog}, usageParts...), indent, true)
	} else {
		lines = append([]string{prog}, getLines(usageParts, strings.Repeat(" ", len(prefix)), false)...)
	}
	return prefix + strings.Join(lines, "\n") + "\n"
}

// formatHelp is parser.format_help() for a formatter of the given width.
func formatHelp(width int) string {
	const indent = 2
	maxHelpPosition := min(24, max(width-20, 4))
	// argparse takes min(longest invocation + 2, maxHelpPosition); the longest invocation here
	// (--max-string-len MAX_STRING_LEN) is wider than any cap, so the cap is always the position.
	helpPosition := maxHelpPosition
	helpWidth := max(width-helpPosition, 11)
	actionWidth := helpPosition - indent - 2
	var b strings.Builder
	b.WriteString(formatUsage(width))
	b.WriteString("\noptions:\n")
	for _, s := range specs {
		if s.help == "" {
			continue
		}
		inv := invocation(s)
		lines := wrapWords(s.help, helpWidth)
		pad := strings.Repeat(" ", helpPosition)
		if len(inv) <= actionWidth {
			fmt.Fprintf(&b, "%*s%-*s  %s\n", indent, "", actionWidth, inv, lines[0])
			lines = lines[1:]
		} else {
			fmt.Fprintf(&b, "%*s%s\n", indent, "", inv)
			b.WriteString(pad + lines[0] + "\n")
			lines = lines[1:]
		}
		for _, l := range lines {
			b.WriteString(pad + l + "\n")
		}
	}
	return b.String()
}

// invocation is how the help lists an option: "-h, --help" or "--input INPUT".
func invocation(s optSpec) string {
	if s.kind == kindHelp {
		return strings.Join(s.flags, ", ")
	}
	return s.flags[0] + " " + s.metavar
}

// wrapWords is textwrap.wrap for text without long words: greedy fill at width.
func wrapWords(text string, width int) []string {
	var lines []string
	cur := ""
	for _, w := range strings.Fields(text) {
		switch {
		case cur == "":
			cur = w
		case len(cur)+1+len(w) <= width:
			cur += " " + w
		default:
			lines = append(lines, cur)
			cur = w
		}
	}
	return append(lines, cur)
}

// pyPath is str(Path(s)): empty and "." components and repeated slashes dropped, "." for nothing left, and a
// leading "//" (exactly two slashes) kept.
func pyPath(s string) string {
	var parts []string
	for _, c := range strings.Split(s, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	root := ""
	switch {
	case strings.HasPrefix(s, "///"), s == "/", strings.HasPrefix(s, "/") && !strings.HasPrefix(s, "//"):
		root = "/"
	case strings.HasPrefix(s, "//"):
		root = "//"
	}
	if joined := strings.Join(parts, "/"); root != "" || joined != "" {
		return root + joined
	}
	return "."
}
