package scoreloop

import (
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
)

// scriptName prefixes every message: the legacy script's name is part of its output contract.
const scriptName = "score-loop-transcript.sh"

// Defaults of the overridable heuristics (RSDD_* environment variables). Data only: logic never inlines them.
const (
	defaultBlockCommit = `^(research|block)\([^)]+\): (.*)$`
	defaultBlockID     = `B([0-9]+)(-B([0-9]+))?`
	defaultQuestion    = "\\?[*_`]*$|shall I|should I|do you want"
	defaultStopToken   = `^STOP:`
	defaultOperatorJQ  = `(.type=="user") and ((.origin.kind // "")=="human")`
	defaultCompactJQ   = `(.type=="system" and (.subtype // "")=="compact_boundary") or (.isCompactSummary // false)`
	defaultGraceMin    = 10
	defaultRangeCap    = 50
)

// Config is the environment-derived configuration of one run.
type Config struct {
	GraceMin    int64    // RSDD_C4_AFTER_STOP_GRACE, minutes
	RangeCap    *big.Int // RSDD_BLOCK_RANGE_CAP
	BlockCommit *regexp.Regexp
	BlockID     *regexp.Regexp
	Question    *regexp.Regexp // matched case-insensitively
	StopToken   *regexp.Regexp
	OperatorJQ  string // "" = the built-in filter
	CompactJQ   string // "" = the built-in filter
	StatusEnv   string // RSDD_STATUS_SCRIPT, "" = the default script
}

// envOr is bash's ${KEY:-def}: an empty value counts as unset.
func envOr(getenv func(string) string, key, def string) string {
	if v := getenv(key); v != "" {
		return v
	}
	return def
}

// loadConfig reads and validates the environment. The first problem is returned as the message of an exit-2 usage
// error, in the legacy order: grace, range cap, then (new) the four regular expressions.
func loadConfig(getenv func(string) string) (Config, string) {
	var c Config
	grace := envOr(getenv, "RSDD_C4_AFTER_STOP_GRACE", strconv.Itoa(defaultGraceMin))
	n, ok := parseCount(grace)
	if !ok {
		return c, fmt.Sprintf("%s: RSDD_C4_AFTER_STOP_GRACE must be a non-negative integer (minutes), got: %s", scriptName, grace)
	}
	c.GraceMin = n.Int64()
	if !n.IsInt64() {
		c.GraceMin = math.MaxInt64
	}
	capText := envOr(getenv, "RSDD_BLOCK_RANGE_CAP", strconv.Itoa(defaultRangeCap))
	rc, ok := parseCount(capText)
	if !ok {
		return c, fmt.Sprintf("%s: RSDD_BLOCK_RANGE_CAP must be a non-negative integer, got: %s", scriptName, capText)
	}
	c.RangeCap = rc
	c.OperatorJQ, c.CompactJQ = getenv("RSDD_OPERATOR_INPUT_JQ"), getenv("RSDD_COMPACT_JQ")
	c.StatusEnv = getenv("RSDD_STATUS_SCRIPT")
	return compileRegexps(&c, getenv)
}

var digitsOnly = regexp.MustCompile(`^[0-9]+$`)

// parseCount reads a non-negative decimal integer of any length (leading zeros are decimal: bash read them as octal).
func parseCount(s string) (*big.Int, bool) {
	if !digitsOnly.MatchString(s) {
		return nil, false
	}
	n, ok := new(big.Int).SetString(s, 10)
	return n, ok
}

// regexpSpec names one overridable expression: its variable, default, case folding and capture-group floor.
type regexpSpec struct {
	env, def string
	fold     bool
	groups   int
	what     string
	dst      func(*Config) **regexp.Regexp
}

var regexpSpecs = []regexpSpec{
	{"RSDD_BLOCK_COMMIT_REGEX", defaultBlockCommit, false, 2, "capture groups (prefix, text after the colon)", func(c *Config) **regexp.Regexp { return &c.BlockCommit }},
	{"RSDD_BLOCK_ID_REGEX", defaultBlockID, false, 1, "capture group (the start block number)", func(c *Config) **regexp.Regexp { return &c.BlockID }},
	{"RSDD_QUESTION_REGEX", defaultQuestion, true, 0, "", func(c *Config) **regexp.Regexp { return &c.Question }},
	{"RSDD_STOP_TOKEN_REGEX", defaultStopToken, false, 0, "", func(c *Config) **regexp.Regexp { return &c.StopToken }},
}

// compileRegexps compiles the overrides (RE2 syntax, leftmost-longest like bash's ERE). Bash silently treated an
// invalid expression as "never matches" and an under-grouped one as an unbound-variable crash, so a run could score
// zero without saying why; both are exit-2 usage errors here.
func compileRegexps(c *Config, getenv func(string) string) (Config, string) {
	for _, sp := range regexpSpecs {
		src := envOr(getenv, sp.env, sp.def)
		pat := src
		if sp.fold {
			pat = "(?i)" + src
		}
		re, err := regexp.Compile(pat)
		if err != nil {
			return *c, fmt.Sprintf("%s: %s is not a valid regular expression: %v", scriptName, sp.env, err)
		}
		if re.NumSubexp() < sp.groups {
			return *c, fmt.Sprintf("%s: %s needs at least %d %s, got %d", scriptName, sp.env, sp.groups, sp.what, re.NumSubexp())
		}
		re.Longest()
		*sp.dst(c) = re
	}
	return *c, ""
}
