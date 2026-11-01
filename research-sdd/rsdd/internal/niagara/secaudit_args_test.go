package niagara

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	saUsage = "usage: niagara-security-audit [-h] [--station FILE] --output JSON INSTALL_ROOT\n"
	saHelp  = saUsage + "\nRead-only Niagara N4 install-directory security-posture auditor. No\n" +
		"subprocesses, no network I/O, no writes to input.\n\n" +
		"positional arguments:\n" +
		"  INSTALL_ROOT    Niagara N4 install directory (niagara_home)\n\n" +
		"options:\n" +
		"  -h, --help      show this help message and exit\n" +
		"  --station FILE  station config.bog for SEC-08/SEC-10/SEC-12 checks\n" +
		"  --output JSON   output JSON evidence file (must not already exist)\n"
)

func saUsageErr(msg string) string { return saUsage + "niagara-security-audit: error: " + msg + "\n" }

// runSA executes security-audit in-process and returns its exit code and streams.
func runSA(args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: func(string) string { return "" }, Clock: time.Now, Cwd: "/work",
	}
	code = RunSecurityAudit(args, s)
	return code, out.String(), errb.String()
}

// auditArgTable pins the output of the legacy argparse parser (CPython 3.15, COLUMNS=80) for the argument
// vectors a caller can produce. The parity test runs the same vectors against the frozen script.
func auditArgTable() []argCase {
	const (
		missingBoth = "the following arguments are required: INSTALL_ROOT, --output"
		missingOut  = "the following arguments are required: --output"
		missingRoot = "the following arguments are required: INSTALL_ROOT"
		oneArgOut   = "argument --output: expected one argument"
		oneArgStn   = "argument --station: expected one argument"
	)
	noFile := func(p string) string { return "niagara-security-audit: " + p + ": No such file or directory\n" }
	return []argCase{
		{"no arguments", nil, 2, "", saUsageErr(missingBoth)},
		{"--help", []string{"--help"}, 0, saHelp, ""},
		{"-h", []string{"-h"}, 0, saHelp, ""},
		{"-h glued to more text", []string{"-hX"}, 0, saHelp, ""},
		{"abbreviated --h", []string{"--h"}, 0, saHelp, ""},
		{"help after a complete command line", []string{"foo", "--output", "o.json", "-h"}, 0, saHelp, ""},
		{"root only", []string{"foo"}, 2, "", saUsageErr(missingOut)},
		{"output only", []string{"--output", "o.json"}, 2, "", saUsageErr(missingRoot)},
		{"output without a value", []string{"foo", "--output"}, 2, "", saUsageErr(oneArgOut)},
		{"station without a value", []string{"foo", "--output", "o.json", "--station"}, 2, "", saUsageErr(oneArgStn)},
		{"a second positional is unrecognized", []string{"foo", "bar", "--output", "o.json"}, 2, "", saUsageErr("unrecognized arguments: bar")},
		{"unknown option is unrecognized once the rest is complete", []string{"foo", "-x", "--output", "o.json"}, 2, "", saUsageErr("unrecognized arguments: -x")},
		{"unknown option alone: required is reported first", []string{"-x"}, 2, "", saUsageErr(missingBoth)},
		{"the root may follow the options", []string{"--output", "o.json", "--station", "s.bog", "foo", "bar"}, 2, "", saUsageErr("unrecognized arguments: bar")},
		{"-- turns the next word into the root", []string{"--output", "o.json", "--", "foo", "bar"}, 2, "", saUsageErr("unrecognized arguments: bar")},
		{"-- as the root", []string{"--output", "o.json", "--", "--"}, 2, "", noFile("--")},
		{"-- then -- then more", []string{"--output", "o.json", "--", "--", "x"}, 2, "", saUsageErr("unrecognized arguments: x")},
		{"a root then -- swallows the separator", []string{"foo", "--", "--output", "o.json"}, 2, "", saUsageErr(missingOut)},
		{"a root then -- leaves the words after it as extras", []string{"--output", "o.json", "foo", "--", "x"}, 2, "", saUsageErr("unrecognized arguments: x")},
		{"everything after -- is positional", []string{"--", "foo", "--output", "o.json"}, 2, "", saUsageErr(missingOut)},
		{"-- then the options are positional", []string{"--", "--output", "o.json"}, 2, "", saUsageErr(missingOut)},
		{"option followed by -- has no value", []string{"foo", "--output", "--", "x"}, 2, "", saUsageErr(oneArgOut)},
		{"abbreviation --s is --station", []string{"--s", "a"}, 2, "", saUsageErr(missingBoth)},
		{"abbreviations with values", []string{"--out", "o.json", "foo"}, 2, "", noFile("foo")},
		{"--option=value form", []string{"--out=o.json", "foo", "--st="}, 2, "", noFile("foo")},
		{"last --output wins", []string{"--output=a", "--output=b", "foo"}, 2, "", noFile("foo")},
		{"last --station wins", []string{"--station=a", "--station", "b", "--", "foo", "--output", "o.json"}, 2, "", saUsageErr(missingOut)},
		{"ambiguous abbreviation", []string{"--=x"}, 2, "", saUsageErr("ambiguous option: --=x could match --help, --station, --output")},
		{"--help with an explicit value", []string{"--help=x"}, 2, "", saUsageErr("argument -h/--help: ignored explicit argument 'x'")},
		{"-h with an explicit value", []string{"-h=x"}, 2, "", saUsageErr("argument -h/--help: ignored explicit argument 'x'")},
		{"a negative number is the root", []string{"-5", "--output", "o.json"}, 2, "", noFile("-5")},
		{"a negative decimal with trailing text is a leftover", []string{"--output", "o.json", "-5", "-.5x", "foo"}, 2, "", saUsageErr("unrecognized arguments: -.5x foo")},
		{"option as the value of --output", []string{"foo", "--output", "-x"}, 2, "", saUsageErr(oneArgOut)},
		{"absent root", []string{"/definitely/not/here", "--output", "o.json"}, 2, "", noFile("/definitely/not/here")},
	}
}

func TestAuditArgumentParsingMatchesArgparse(t *testing.T) {
	for _, tt := range auditArgTable() {
		t.Run(tt.name, func(t *testing.T) {
			code, out, errs := runSA(tt.args...)
			if code != tt.code || out != tt.out || errs != tt.err {
				t.Errorf("args %q\n got  code=%d stdout=%q stderr=%q\n want code=%d stdout=%q stderr=%q", tt.args, code, out, errs, tt.code, tt.out, tt.err)
			}
		})
	}
}
