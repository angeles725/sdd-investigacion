package sizecheck

import (
	"fmt"
	"strconv"
	"strings"
)

// Defaults of the review budget (CLAUDE.md section 6): the hard limit is twice the budget.
const (
	defaultBudget = 400
	maxDigits     = 9
)

// options is what the command line said.
type options struct {
	base, head string
	budget     int
	hard       int
	strict     bool
	format     string // "report" or "json"
	help       bool
}

// failure is a refused command line or a typed degraded state: the why of `degraded: kit-size-check: <why>`, whether
// the usage text goes to stderr first, and the format the degraded document is printed in.
type failure struct {
	why       string
	showUsage bool
	format    string
}

func (f *failure) Error() string { return f.why }

// parse is the strict parser of this command: every fault is a degraded state (the bash tool's contract), checked in
// its order, so two faults report the first. Numbers are digits only, at most nine of them, read as base 10.
func parse(args []string) (options, *failure) {
	o := options{head: "HEAD", budget: defaultBudget, format: "report"}
	hard, hardGiven, budgetRaw := "", false, strconv.Itoa(defaultBudget)
	rest := args
	need := func(flag string) (string, *failure) {
		if len(rest) < 2 {
			return "", &failure{why: flag + " needs a value", format: o.format}
		}
		v := rest[1]
		rest = rest[2:]
		return v, nil
	}
	for len(rest) > 0 {
		var err *failure
		switch a := rest[0]; a {
		case "--base":
			o.base, err = need(a)
		case "--head":
			o.head, err = need(a)
		case "--budget":
			budgetRaw, err = need(a)
		case "--hard-limit":
			if hard, err = need(a); err == nil {
				hardGiven = true
			}
		case "--format":
			o.format, err = need(a)
		case "--strict":
			o.strict = true
			rest = rest[1:]
		case "-h", "--help":
			o.help = true
			return o, nil
		default:
			return o, &failure{why: "unknown argument: " + a, showUsage: true, format: o.format}
		}
		if err != nil {
			return o, err
		}
	}
	if o.format != "report" && o.format != "json" {
		return o, &failure{why: "--format must be report or json", format: "report"}
	}
	if o.base == "" {
		return o, &failure{why: "--base is required", showUsage: true, format: o.format}
	}
	return o, numbers(&o, budgetRaw, hard, hardGiven)
}

// numbers validates --budget and --hard-limit and fills them in.
func numbers(o *options, budgetRaw, hardRaw string, hardGiven bool) *failure {
	bad := func(why string) *failure { return &failure{why: why, format: o.format} }
	if !digits(budgetRaw) {
		return bad("--budget must be a positive integer: " + budgetRaw)
	}
	if len(budgetRaw) > maxDigits {
		return bad("--budget must be a positive integer of at most 9 digits: " + budgetRaw)
	}
	o.budget, _ = strconv.Atoi(budgetRaw)
	if o.budget < 1 {
		return bad(fmt.Sprintf("--budget must be a positive integer: %d", o.budget))
	}
	o.hard = o.budget * 2
	if hardGiven {
		if !digits(hardRaw) {
			return bad("--hard-limit must be a positive integer: " + hardRaw)
		}
		if len(hardRaw) > maxDigits {
			return bad("--hard-limit must be a positive integer of at most 9 digits: " + hardRaw)
		}
		o.hard, _ = strconv.Atoi(hardRaw)
	}
	if o.hard < o.budget {
		return bad(fmt.Sprintf("--hard-limit (%d) must be >= --budget (%d)", o.hard, o.budget))
	}
	return nil
}

// digits is a non-empty run of ASCII digits.
func digits(s string) bool { return s != "" && strings.Trim(s, "0123456789") == "" }
