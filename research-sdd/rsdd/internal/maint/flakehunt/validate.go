package flakehunt

import (
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// config is a validated hunt: every number is a number, the tier and the filing mode are known words.
type config struct {
	o                                     options
	runs, load, loadTimeout, suiteTimeout int // loadTimeout 0: derive it once the suites are known
}

// natural parses a non-empty run of digits that fits an int (bash's isint plus a range the arithmetic could hold).
func natural(s string) (int, bool) {
	if s == "" || !kitmaint.AllDigits(s) {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	return n, err == nil
}

// isSpace is bash's [[:space:]] in the C locale.
func isSpace(r rune) bool { return strings.ContainsRune(" \t\n\v\f\r", r) }

// validate judges the raw values in the order of the bash tool, so two faults report the first one. nproc is asked
// only when --load was not given (an empty --load counts as not given).
func validate(o options, nproc func() (int, bool)) (config, *stop) {
	c := config{o: o}
	var ok bool
	if c.runs, ok = natural(o.runs); !ok || c.runs < 1 {
		return c, bad("--runs must be an integer >= 1 (got '%s')", o.runs)
	}
	if o.load == "" {
		n, ok := nproc()
		if !ok || n < 1 {
			return c, die("nproc gave no usable CPU count; pass --load N explicitly")
		}
		c.load = max(n/2, 1)
	} else if c.load, ok = natural(o.load); !ok {
		return c, bad("--load must be an integer >= 0 (got '%s')", o.load)
	}
	if o.loadTimeout != "" {
		if c.loadTimeout, ok = natural(o.loadTimeout); !ok || c.loadTimeout < 1 {
			return c, bad("--load-timeout must be an integer >= 1")
		}
	}
	if c.suiteTimeout, ok = natural(o.suiteTimeout); !ok || c.suiteTimeout < 1 {
		return c, bad("--suite-timeout must be an integer >= 1")
	}
	if o.tier != "core" && o.tier != "all" {
		return c, bad("--tier must be core or all (got '%s')", o.tier)
	}
	if e := o.evidence; e != "" {
		if !strings.HasPrefix(e, "http://") && !strings.HasPrefix(e, "https://") {
			return c, bad("--evidence-url must be an http(s) URL (got '%s')", e)
		}
		if strings.IndexFunc(e, isSpace) >= 0 {
			return c, bad("--evidence-url must be one http(s) URL without whitespace")
		}
	}
	if o.suitesFile != "" && len(o.suiteArgs) > 0 {
		return c, bad("--suites and --suite are mutually exclusive")
	}
	return c, nil
}
