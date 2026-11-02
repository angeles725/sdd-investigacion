package serial

import (
	"fmt"
	"math/big"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// A small argparse look-alike for the two serial-frame commands. The legacy scripts used Python's argparse with
// one required sub-command and long options only; the behaviour that matters to callers is kept: `--opt value`
// and `--opt=value`, unambiguous prefixes of an option name, a value that starts with "-" only when it is a
// negative number or contains a space, typed values (int, float), required options reported together, and
// exit code 2 on every usage error. The message wording is the Go port's own (a documented difference).

type argKind int

const (
	argString argKind = iota
	argInt
	argFloat
	argFlag
)

type argSpec struct {
	name     string // without the leading "--"
	kind     argKind
	required bool
	metavar  string
}

type subSpec struct {
	name string
	args []argSpec
}

// cmdLine holds the parse result: the chosen sub-command and the typed values by option name.
type cmdLine struct {
	prog   string
	about  string
	subs   []subSpec
	sub    string
	strs   map[string]string
	ints   map[string]*big.Int
	floats map[string]float64
	flags  map[string]bool
}

var negativeNumber = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

func (c *cmdLine) usageLine(sub subSpec) string {
	var b strings.Builder
	fmt.Fprintf(&b, "usage: %s %s [-h]", c.prog, sub.name)
	for _, a := range sub.args {
		item := "--" + a.name
		if a.kind != argFlag {
			item += " " + a.metavar
		}
		if !a.required {
			item = "[" + item + "]"
		}
		b.WriteString(" " + item)
	}
	return b.String() + "\n"
}

func (c *cmdLine) topUsage() string {
	names := make([]string, len(c.subs))
	for i, sub := range c.subs {
		names[i] = sub.name
	}
	return fmt.Sprintf("usage: %s [-h] {%s} ...\n\n%s\n", c.prog, strings.Join(names, ","), c.about)
}

func (c *cmdLine) fail(s cli.Stdio, usage, format string, v ...any) int {
	fmt.Fprint(s.Err, usage)
	prog := c.prog
	if c.sub != "" {
		prog += " " + c.sub
	}
	fmt.Fprintf(s.Err, "%s: error: %s\n", prog, fmt.Sprintf(format, v...))
	return cli.ExitUsage
}

// parse reads args. done is true when the command must stop with code (usage error or help).
func (c *cmdLine) parse(args []string, s cli.Stdio) (code int, done bool) {
	if len(args) == 0 {
		return c.fail(s, c.topUsage(), "the following arguments are required: cmd"), true
	}
	if args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(s.Out, c.topUsage())
		return cli.ExitOK, true
	}
	var sub *subSpec
	for i := range c.subs {
		if c.subs[i].name == args[0] {
			sub = &c.subs[i]
		}
	}
	if sub == nil {
		return c.fail(s, c.topUsage(), "argument cmd: invalid choice: %s", pyRepr(args[0])), true
	}
	c.sub = sub.name
	c.strs, c.ints, c.floats, c.flags = map[string]string{}, map[string]*big.Int{}, map[string]float64{}, map[string]bool{}
	usage := c.usageLine(*sub)
	given := map[string]bool{}
	var extra []string
	rest := args[1:]
	for i := 0; i < len(rest); i++ {
		arg := rest[i]
		if arg == "-h" || arg == "--help" {
			fmt.Fprint(s.Out, usage)
			return cli.ExitOK, true
		}
		if !c.looksLikeOption(*sub, arg) {
			extra = append(extra, arg)
			continue
		}
		name, explicit, hasExplicit := strings.Cut(arg, "=")
		spec, msg := c.resolve(*sub, name, arg)
		if msg != "" {
			return c.fail(s, usage, "%s", msg), true
		}
		if spec == nil {
			extra = append(extra, arg)
			continue
		}
		given[spec.name] = true
		if spec.kind == argFlag {
			if hasExplicit {
				return c.fail(s, usage, "argument --%s: ignored explicit argument %s", spec.name, pyRepr(explicit)), true
			}
			c.flags[spec.name] = true
			continue
		}
		value := explicit
		if !hasExplicit {
			if i+1 >= len(rest) || c.looksLikeOption(*sub, rest[i+1]) {
				return c.fail(s, usage, "argument --%s: expected one argument", spec.name), true
			}
			i++
			value = rest[i]
		}
		if msg := c.store(*spec, value); msg != "" {
			return c.fail(s, usage, "%s", msg), true
		}
	}
	var missing []string
	for _, a := range sub.args {
		if a.required && !given[a.name] {
			missing = append(missing, "--"+a.name)
		}
	}
	if len(missing) > 0 {
		return c.fail(s, usage, "the following arguments are required: %s", strings.Join(missing, ", ")), true
	}
	if len(extra) > 0 {
		return c.fail(s, c.topUsage(), "unrecognized arguments: %s", strings.Join(extra, " ")), true
	}
	return 0, false
}

func (c *cmdLine) store(a argSpec, value string) string {
	switch a.kind {
	case argInt:
		v, ok := pyParseInt(value)
		if !ok {
			return fmt.Sprintf("argument --%s: invalid int value: %s", a.name, pyRepr(value))
		}
		c.ints[a.name] = v
	case argFloat:
		v, ok := pyParseFloat(value)
		if !ok {
			return fmt.Sprintf("argument --%s: invalid float value: %s", a.name, pyRepr(value))
		}
		c.floats[a.name] = v
	default:
		c.strs[a.name] = value
	}
	return ""
}

// matches lists the options of sub that name starts with.
func matches(sub subSpec, name string) []*argSpec {
	var out []*argSpec
	if !strings.HasPrefix(name, "--") {
		return nil
	}
	for i := range sub.args {
		if strings.HasPrefix("--"+sub.args[i].name, name) {
			out = append(out, &sub.args[i])
		}
	}
	return out
}

// looksLikeOption is argparse's classification of one argument string as an option (true) or a value.
func (c *cmdLine) looksLikeOption(sub subSpec, arg string) bool {
	switch {
	case arg == "" || arg[0] != '-' || arg == "-":
		return false
	case len(matches(sub, strings.SplitN(arg, "=", 2)[0])) > 0:
		return true
	case negativeNumber.MatchString(arg), strings.Contains(arg, " "):
		return false
	}
	return true
}

// resolve maps an option string (name part, before any "=") to its spec: an option name or a unique prefix of
// one (no option name here is a prefix of another, so an exact name is always unique). A nil spec with no
// message is an unknown option.
func (c *cmdLine) resolve(sub subSpec, name, arg string) (*argSpec, string) {
	found := matches(sub, name)
	switch len(found) {
	case 0:
		return nil, ""
	case 1:
		return found[0], ""
	}
	names := make([]string, len(found))
	for i, m := range found {
		names[i] = "--" + m.name
	}
	return nil, fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(names, ", "))
}
