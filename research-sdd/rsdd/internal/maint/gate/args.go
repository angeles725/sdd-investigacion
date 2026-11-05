package gate

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitgate"
)

const usageLine = "kit-gate.sh [--cmd CMD] [--state-dir DIR] <worktree> <label>"

// options is what the command line said.
type options struct {
	cmd, state  string
	serial      bool
	cmdGiven    bool
	lockTimeout string
	wt, label   string
	help        bool
}

// usageError is a refused command line: the message after `kit-gate: usage: `.
type usageError string

func (e usageError) Error() string { return string(e) }

// parse is the strict parser of this command: an unknown word starting with `-` is a usage error, the first word that
// does not start with `-` ends the options, and exactly two positionals (worktree, label) must remain.
// lockEnv is KIT_GATE_LOCK_TIMEOUT. The checks run in the order of the bash tool, so two faults report the first.
func parse(args []string, lockEnv string) (options, error) {
	o := options{lockTimeout: lockEnv}
	if o.lockTimeout == "" {
		o.lockTimeout = kitgate.DefaultLockTimeout
	}
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
		case a == "--cmd":
			o.cmd, err = value(a)
			o.cmdGiven = true
		case a == "--lock-timeout":
			o.lockTimeout, err = value(a)
		case a == "--state-dir":
			o.state, err = value(a)
		case a == "--serial":
			o.serial = true
			rest = rest[1:]
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
	o.wt, o.label = rest[0], rest[1]
	return o, o.validate()
}

// validate is the bash checks after the positionals, in order: label, lock timeout, --serial with --cmd.
func (o options) validate() error {
	if o.label == "" || strings.Trim(o.label, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") != "" {
		return usageError("label must match [A-Za-z0-9._-]+")
	}
	if !kitgate.ValidLockTimeout(o.lockTimeout) {
		return usageError(kitgate.MsgBadLockTimeout)
	}
	if o.serial && o.cmdGiven {
		return usageError("--serial cannot be combined with --cmd")
	}
	return nil
}
