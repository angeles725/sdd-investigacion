package prpipeline

import "strings"

const usageLine = "kit-pr-pipeline.sh [options] <worktree> <pr> <remote-branch>"

// options is what the command line said.
type options struct {
	dryRun, serial, noGate bool
	consent                string // "" or "granted"
	gateCmd, sizeCheck     string
	state, base, remote    string
	wt, pr, branch         string
	help                   bool
}

// usageError is a refused command line: the message after `kit-pr-pipeline: usage: `.
type usageError string

func (e usageError) Error() string { return string(e) }

// parse is the strict parser of this command: an unknown word starting with `-` is a usage error, the first word that
// does not start with `-` ends the options, and exactly three positionals (worktree, pr, remote-branch) must remain.
// The checks run in the order of the bash tool, so two faults report the first.
func parse(args []string) (options, error) {
	o := options{base: "origin/main", remote: "origin"}
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
		switch a := rest[0]; a {
		case "--dry-run":
			o.dryRun = true
			rest = rest[1:]
		case "--consent":
			if len(rest) < 2 || rest[1] != "granted" {
				return o, usageError("--consent takes the single value: granted")
			}
			o.consent = "granted"
			rest = rest[2:]
		case "--serial":
			o.serial = true
			rest = rest[1:]
		case "--no-gate":
			o.noGate = true
			rest = rest[1:]
		case "--gate-cmd":
			o.gateCmd, err = value(a)
		case "--size-check":
			o.sizeCheck, err = value(a)
		case "--state-dir":
			o.state, err = value(a)
		case "--base-ref":
			o.base, err = value(a)
		case "--remote":
			o.remote, err = value(a)
		case "-h", "--help":
			o.help = true
			return o, nil
		case "--":
			rest = rest[1:]
			break loop
		default:
			if strings.HasPrefix(a, "-") {
				return o, usageError("unknown option " + a)
			}
			break loop
		}
		if err != nil {
			return o, err
		}
	}
	if len(rest) != 3 {
		return o, usageError(usageLine)
	}
	if o.serial && o.gateCmd != "" {
		return o, usageError("--serial cannot be combined with --gate-cmd")
	}
	o.wt, o.pr, o.branch = rest[0], rest[1], rest[2]
	if o.pr == "" || strings.Trim(o.pr, "0123456789") != "" {
		return o, usageError("pr must be a number: " + o.pr)
	}
	return o, nil
}
