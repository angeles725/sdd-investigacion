package niagara

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	wantUsage = "usage: bog-nav [-h] --input BOG --output JSON\n"
	wantHelp  = wantUsage + "\nNiagara N4 config.bog structural evidence extractor.\n\noptions:\n" +
		"  -h, --help     show this help message and exit\n" +
		"  --input BOG    config.bog (ZIP-compressed file.xml) or bare XML file\n" +
		"  --output JSON  output JSON evidence file path (must not already exist)\n"
)

func usageErr(msg string) string { return wantUsage + "bog-nav: error: " + msg + "\n" }

// run executes the command in-process and returns its exit code and streams.
func run(args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: func(string) string { return "" }, Clock: time.Now, Cwd: "/work",
	}
	code = RunBogNav(args, s)
	return code, out.String(), errb.String()
}

// TestArgumentParsingMatchesArgparse pins the exact output of the legacy argparse parser (CPython 3.15,
// COLUMNS=80) for the argument vectors a caller can produce. The same vectors run against the frozen Python in
// the differential test, so this table cannot drift from the oracle unnoticed.
func TestArgumentParsingMatchesArgparse(t *testing.T) {
	for _, tt := range argparseTable() {
		t.Run(tt.name, func(t *testing.T) {
			code, out, errs := run(tt.args...)
			if code != tt.code || out != tt.out || errs != tt.err {
				t.Errorf("args %q\n got  code=%d stdout=%q stderr=%q\n want code=%d stdout=%q stderr=%q", tt.args, code, out, errs, tt.code, tt.out, tt.err)
			}
		})
	}
}

type argCase struct {
	name string
	args []string
	code int
	out  string
	err  string
}

func argparseTable() []argCase {
	const (
		missingBoth = "the following arguments are required: --input, --output"
		missingOut  = "the following arguments are required: --output"
		missingIn   = "the following arguments are required: --input"
		oneArgIn    = "argument --input: expected one argument"
	)
	noFile := func(p string) string { return "bog-nav: " + p + ": No such file or directory\n" }
	return []argCase{
		{"no arguments", nil, 2, "", usageErr(missingBoth)},
		{"--help", []string{"--help"}, 0, wantHelp, ""},
		{"-h", []string{"-h"}, 0, wantHelp, ""},
		{"abbreviated --he", []string{"--he"}, 0, wantHelp, ""},
		{"abbreviated --h", []string{"--h"}, 0, wantHelp, ""},
		{"-h glued to more text prints the help (CPython 3.15 runs the action first)", []string{"-hX"}, 0, wantHelp, ""},
		{"help wins over a later unknown option", []string{"-h", "--bogus"}, 0, wantHelp, ""},
		{"help after an unknown option still prints help", []string{"--bogus", "-h"}, 0, wantHelp, ""},
		{"input only", []string{"--input", "a"}, 2, "", usageErr(missingOut)},
		{"output only", []string{"--output", "b"}, 2, "", usageErr(missingIn)},
		{"input without a value", []string{"--input"}, 2, "", usageErr(oneArgIn)},
		{"output without a value", []string{"--input", "a", "--output"}, 2, "", usageErr("argument --output: expected one argument")},
		{"a positional alone: required is reported first", []string{"x"}, 2, "", usageErr(missingBoth)},
		{"extra positional", []string{"--input", "a", "--output", "b", "extra"}, 2, "", usageErr("unrecognized arguments: extra")},
		{"unknown option alone: required is reported first", []string{"--bogus"}, 2, "", usageErr(missingBoth)},
		{"unknown option after both", []string{"-x", "--input", "a", "--output", "b"}, 2, "", usageErr("unrecognized arguments: -x")},
		{"unknown long option with =", []string{"--bogus=1", "--input", "a", "--output", "b"}, 2, "", usageErr("unrecognized arguments: --bogus=1")},
		{"unknown option containing a space", []string{"-x y", "--input", "a", "--output", "b"}, 2, "", usageErr("unrecognized arguments: -x y")},
		{"after -- everything is positional", []string{"--", "--input", "a"}, 2, "", usageErr(missingBoth)},
		{"-- then the second option is positional", []string{"--input", "a", "--", "--output", "b"}, 2, "", usageErr(missingOut)},
		{"trailing --", []string{"--input", "a", "--output", "b", "--"}, 2, "", usageErr("unrecognized arguments: --")},
		{"-- with a value after it", []string{"--input", "a", "--output", "b", "--", "x"}, 2, "", usageErr("unrecognized arguments: -- x")},
		{"mixed leftovers keep their order", []string{"--input", "a", "--output", "b", "x", "--bogus", "--", "y"}, 2, "", usageErr("unrecognized arguments: x --bogus -- y")},
		{"a dash is a positional", []string{"--input", "a", "--output", "b", "-"}, 2, "", usageErr("unrecognized arguments: -")},
		{"a negative number is a positional", []string{"--input", "a", "--output", "b", "-5"}, 2, "", usageErr("unrecognized arguments: -5")},
		{"a negative decimal is a positional", []string{"--input", "a", "--output", "b", "-1.5"}, 2, "", usageErr("unrecognized arguments: -1.5")},
		{"two unknown options", []string{"--input", "a", "-x", "--output", "b", "-y"}, 2, "", usageErr("unrecognized arguments: -x -y")},
		{"--x y is one positional-like token", []string{"--input", "a", "--output", "b", "--x y"}, 2, "", usageErr("unrecognized arguments: --x y")},
		{"option as the value of --input", []string{"--input", "-x"}, 2, "", usageErr(oneArgIn)},
		{"-- as the value of --input", []string{"--input", "--", "--output", "b"}, 2, "", usageErr(oneArgIn)},
		{"--help as the value of --input", []string{"--input", "--help"}, 2, "", usageErr(oneArgIn)},
		{"--output as the value of --input", []string{"--input", "--output", "b"}, 2, "", usageErr(oneArgIn)},
		{"a repeated --input needs a value too", []string{"--input", "a", "--output", "b", "--input"}, 2, "", usageErr(oneArgIn)},
		{"--help with an explicit value", []string{"--help=x"}, 2, "", usageErr("argument -h/--help: ignored explicit argument 'x'")},
		{"-h with an explicit value", []string{"-h=1"}, 2, "", usageErr("argument -h/--help: ignored explicit argument '1'")},
		{"abbreviated help with an explicit value", []string{"--hel=1"}, 2, "", usageErr("argument -h/--help: ignored explicit argument '1'")},
		{"ambiguous abbreviation", []string{"--=x"}, 2, "", usageErr("ambiguous option: --=x could match --help, --input, --output")},
		{"empty-string argument is a positional", []string{""}, 2, "", usageErr(missingBoth)},
		{"single-dash long name is unknown", []string{"-input", "a"}, 2, "", usageErr(missingBoth)},
		{"option names are case sensitive", []string{"--INPUT", "a"}, 2, "", usageErr(missingBoth)},
		{"abbreviated --i alone", []string{"--i"}, 2, "", usageErr(oneArgIn)},
		{"input value taken from the next token even when it holds a space", []string{"--input", "a b", "--output", "c"}, 2, "", noFile("a b")},
		{"input value may be a lone dash", []string{"--input", "-", "--output", "b"}, 2, "", noFile("-")},
		{"input value may be a negative number", []string{"--input", "-5", "--output", "b"}, 2, "", noFile("-5")},
		{"input value may be a negative decimal", []string{"--input", "-.5", "--output", "b"}, 2, "", noFile("-.5")},
		{"input value may start with a dash and hold a space", []string{"--input", "-x y", "--output", "b"}, 2, "", noFile("-x y")},
		{"--option=value form", []string{"--input=a", "--output=b"}, 2, "", noFile("a")},
		{"empty --input= value", []string{"--input=", "--output=b"}, 2, "", noFile("")},
		{"value containing =", []string{"--input=a=b", "--output=c"}, 2, "", noFile("a=b")},
		{"abbreviations with values", []string{"--inp", "a", "--out", "b"}, 2, "", noFile("a")},
		{"abbreviations with = values", []string{"--i=a", "--o=b"}, 2, "", noFile("a")},
		{"last --input wins", []string{"--input", "zz-first", "--input", "a", "--output", "b"}, 2, "", noFile("a")},
		{"--output= accepted before --input", []string{"--output=", "--input", "a"}, 2, "", noFile("a")},
	}
}
