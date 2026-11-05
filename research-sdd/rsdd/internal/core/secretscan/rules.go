package secretscan

import "regexp"

// rule is one high-confidence secret-value pattern. Each is specific enough to be near-zero false-positive and none
// matches a bare hex hash, a sha256 citation or a byte dump (the load-bearing anti-false-positive). Literals are
// substrings of which at least one must occur in any match: a cheap pre-filter that never changes a verdict.
type rule struct {
	Label    string
	Pattern  string
	Literals []string
	re       *regexp.Regexp
}

// ruleSpecs is the data of the seven rules, in report order.
var ruleSpecs = []rule{
	{Label: "PEM PRIVATE KEY block", Pattern: `-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----`, Literals: []string{"-----BEGIN "}},
	{Label: "AWS access/session key id", Pattern: `A[KS]IA[0-9A-Z]{16}`, Literals: []string{"AKIA", "ASIA"}},
	{Label: "GitHub token", Pattern: `gh[pousr]_[A-Za-z0-9]{36,}`, Literals: []string{"ghp_", "gho_", "ghu_", "ghs_", "ghr_"}},
	{Label: "Slack token", Pattern: `xox[baprs]-[A-Za-z0-9-]{10,}`, Literals: []string{"xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"}},
	{Label: "Google API key", Pattern: `AIza[0-9A-Za-z_-]{35}`, Literals: []string{"AIza"}},
	{Label: "OpenAI-style key", Pattern: `sk-[A-Za-z0-9]{20,}`, Literals: []string{"sk-"}},
	{Label: "JWT", Pattern: `eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}`, Literals: []string{"eyJ"}},
}

// rules are the compiled rules. Longest() gives grep -E's leftmost-longest match, which `grep -o` prints.
var rules = compileRules(ruleSpecs)

func compileRules(specs []rule) []rule {
	out := make([]rule, len(specs))
	for i, r := range specs {
		re := regexp.MustCompile(r.Pattern)
		re.Longest()
		r.re = re
		out[i] = r
	}
	return out
}

// Advisory tier (never changes the exit code): a credential keyword assigned a real-looking literal value.
// advisoryKeywords are matched case-insensitively with a non-alphanumeric boundary before and no letter right after
// (snake_case names such as aws_secret_access_key match; camelCase substrings and ordinary words such as tokenizer
// do not). "api" + optional separator + "key" is handled in advisory.go.
var advisoryKeywords = []string{"password", "passwd", "secret", "token"}

// Caps on the lines one section prints (the legacy `head -50`, `head -200` and `head -20`). The legacy script applied
// the advisory cap BEFORE its placeholder filters, so a keyword line past the 200th was never judged; here the cap
// counts printed warnings, and a cut is announced, never silent.
const (
	capLeaksPerRule   = 50
	capAdvisoryWarns  = 200
	capCommitMessages = 20
)
