package flakehunt

import "testing"

// quoteCases are words whose bash `printf %q` form is pinned literally (they replay under -tags nodiff too).
var quoteCases = map[string]string{
	"":                        "''",
	"plain-name_1.sh":         "plain-name_1.sh",
	"a b":                     `a\ b`,
	"flake: x failed 1/2":     `flake:\ x\ failed\ 1/2`,
	"it's":                    `it\'s`,
	`a"b`:                     `a\"b`,
	"a$b`c`":                  "a\\$b\\`c\\`",
	"(x);y|z&":                `\(x\)\;y\|z\&`,
	"*?[x]{y}<>!^":            `\*\?\[x\]\{y\}\<\>\!\^`,
	"/tmp/o1/issue-x.md":      "/tmp/o1/issue-x.md",
	"a=b:c,d+e%f@g":           `a=b:c\,d+e%f@g`,
	"#x":                      `\#x`,
	"x#":                      "x#",
	"~x":                      `\~x`,
	"x~":                      "x~",
	"a:~b":                    `a:\~b`,
	"a=~b":                    `a=\~b`,
	"a\tb":                    `$'a\tb'`,
	"a\nb":                    `$'a\nb'`,
	"\x1b[0m":                 `$'\E[0m'`,
	"a\x01b":                  `$'a\001b'`,
	"\x7f":                    `$'\177'`,
	"it's\ta":                 `$'it\'s\ta'`,
	`back\slash`:              `back\\slash`,
	"tab\there'q":             `$'tab\there\'q'`,
	"émoji":                   "émoji",
	"/path with space/o1/x":   `/path\ with\ space/o1/x`,
	"\a\b\f\v\r":              `$'\a\b\f\v\r'`,
	`$'quoted'`:               `\$\'quoted\'`,
	"trailing-space ":         `trailing-space\ `,
	"two  spaces":             `two\ \ spaces`,
	"gh":                      "gh",
	"--title":                 "--title",
	"flake: a.test.sh failed": `flake:\ a.test.sh\ failed`,
}

func TestShQuoteMatchesBashPrintfQ(t *testing.T) {
	for in, want := range quoteCases {
		if got := shQuote(in); got != want {
			t.Errorf("shQuote(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestShJoinEndsEveryWordWithASpace(t *testing.T) {
	if got := shJoin([]string{"gh", "issue comment", "7"}); got != `gh issue\ comment 7 ` {
		t.Errorf("got %q", got)
	}
}
