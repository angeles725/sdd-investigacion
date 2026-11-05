package waitmerge

import "strings"

const usageLine = "kit-wait-merge.sh [--base-ref REF] <worktree> <pr>"

// options is what the command line said.
type options struct {
	base, expectHead string
	wt, pr           string
	help             bool
}

// usageError is a refused command line: the message after `kit-wait-merge: usage: `.
type usageError string

func (e usageError) Error() string { return string(e) }

// parse is the strict parser of this command: an unknown word starting with `-` is a usage error, the first word that
// does not start with `-` ends the options, and exactly two positionals (worktree, pr) must remain; the checks run in
// the order of the bash tool, so two faults report the first.
func parse(args []string) (options, error) {
	o := options{base: "origin/main"}
	rest := args
	value := func(flag string) (string, error) {
		if len(rest) < 2 {
			return "", usageError(flag + " needs a value")
		}
		v := rest[1]
		rest = rest[2:]
		return v, nil
	}
loop:
	for len(rest) > 0 {
		var err error
		switch a := rest[0]; {
		case a == "--base-ref":
			o.base, err = value(a)
		case a == "--expect-head":
			o.expectHead, err = value(a)
		case a == "-h" || a == "--help":
			o.help = true
			return o, nil
		case a == "--":
			rest = rest[1:]
			break loop
		case strings.HasPrefix(a, "-"):
			return o, usageError("unknown option " + a)
		default:
			break loop
		}
		if err != nil {
			return o, err
		}
	}
	if len(rest) != 2 {
		return o, usageError(usageLine)
	}
	o.wt, o.pr = rest[0], rest[1]
	if o.pr == "" || strings.Trim(o.pr, "0123456789") != "" {
		return o, usageError("pr must be a number: " + o.pr)
	}
	return o, nil
}
