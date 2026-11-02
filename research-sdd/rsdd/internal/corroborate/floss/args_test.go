package floss

import (
	"bytes"
	"strings"
	"testing"
)

// Expected texts are what `python3.12 corroborate_floss.py` prints (argparse, prog "corroborate-floss").
const usage80 = "usage: corroborate-floss [-h] --input INPUT --output OUTPUT\n" +
	"                         [--timeout TIMEOUT] [--max-strings MAX_STRINGS]\n" +
	"                         [--max-string-len MAX_STRING_LEN]\n"

const usage200 = "usage: corroborate-floss [-h] --input INPUT --output OUTPUT [--timeout TIMEOUT] [--max-strings MAX_STRINGS] [--max-string-len MAX_STRING_LEN]\n"

const help80 = usage80 + `
options:
  -h, --help            show this help message and exit
  --input INPUT         PE/ELF binary to analyse
  --output OUTPUT       New output directory (must not exist)
  --timeout TIMEOUT     Wall-clock timeout for floss (seconds, default 120)
  --max-strings MAX_STRINGS
                        Maximum total strings sampled across all categories
                        (default 2000)
  --max-string-len MAX_STRING_LEN
                        Maximum length of each sampled string value (default
                        256)
`

func parse(args []string, width int) (opts options, code int, done bool, out, errText string) {
	var o, e bytes.Buffer
	opts, code, done = parseArgs(args, width, &o, &e)
	return opts, code, done, o.String(), e.String()
}

func TestParseArgsUsageErrors(t *testing.T) {
	req := []string{"--input", "a", "--output", "b", "--manifest-cli", "c"}
	cases := []struct {
		name  string
		args  []string
		width int
		want  string
	}{
		{"no arguments", nil, 78, usage80 + "corroborate-floss: error: the following arguments are required: --input, --output, --manifest-cli\n"},
		{"manifest-cli is required but not in the usage", []string{"--input", "a", "--output", "b"}, 78, usage80 + "corroborate-floss: error: the following arguments are required: --manifest-cli\n"},
		{"invalid int", append([]string{"--timeout", "x"}, req...), 78, usage80 + "corroborate-floss: error: argument --timeout: invalid int value: 'x'\n"},
		{"unrecognized option", append(append([]string{}, req...), "--bogus"), 78, usage80 + "corroborate-floss: error: unrecognized arguments: --bogus\n"},
		{"unrecognized positional and dashes", append(append([]string{}, req...), "--", "x"), 78, usage80 + "corroborate-floss: error: unrecognized arguments: -- x\n"},
		{"ambiguous abbreviation", append([]string{"--max-s", "3"}, req...), 78, usage80 + "corroborate-floss: error: ambiguous option: --max-s could match --max-strings, --max-string-len\n"},
		{"ambiguous with the hidden option", []string{"--m", "3"}, 78, usage80 + "corroborate-floss: error: ambiguous option: --m could match --max-strings, --max-string-len, --manifest-cli\n"},
		{"missing value", []string{"--input"}, 78, usage80 + "corroborate-floss: error: argument --input: expected one argument\n"},
		{"value is an option", []string{"--input", "--output", "b"}, 78, usage80 + "corroborate-floss: error: argument --input: expected one argument\n"},
		{"help takes no value", []string{"--help=foo"}, 78, usage80 + "corroborate-floss: error: argument -h/--help: ignored explicit argument 'foo'\n"},
		{"wide terminal keeps the usage on one line", nil, 198, usage200 + "corroborate-floss: error: the following arguments are required: --input, --output, --manifest-cli\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, code, done, out, errText := parse(c.args, c.width)
			if !done || code != 2 || out != "" || errText != c.want {
				t.Fatalf("done=%v code=%d stdout=%q\nstderr:\n%s\nwant:\n%s", done, code, out, errText, c.want)
			}
		})
	}
}

func TestParseArgsHelp(t *testing.T) {
	for _, args := range [][]string{{"-h"}, {"--help"}, {"--he"}, {"--input", "a", "-h", "--bogus"}} {
		_, code, done, out, errText := parse(args, 78)
		if !done || code != 0 || errText != "" || out != help80 {
			t.Fatalf("%v: done=%v code=%d stderr=%q\nstdout:\n%s", args, done, code, errText, out)
		}
	}
}

func TestParseArgsHelpFollowsTheTerminalWidth(t *testing.T) {
	_, _, _, out, _ := parse([]string{"-h"}, 198)
	for _, want := range []string{
		usage200 + "\noptions:\n",
		"  --max-strings MAX_STRINGS\n                        Maximum total strings sampled across all categories (default 2000)\n",
		"  --input INPUT         PE/ELF binary to analyse\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("help at width 198 lacks %q:\n%s", want, out)
		}
	}
}

func TestParseArgsReadsEveryOption(t *testing.T) {
	cases := [][]string{
		{"--input", "in", "--output", "out", "--timeout", "7", "--max-strings", "8", "--max-string-len", "9", "--manifest-cli", "m"},
		{"--input=in", "--output=out", "--timeout=7", "--max-strings=8", "--max-string-len=9", "--manifest-cli=m"},
		{"--inp", "in", "--out", "out", "--ti", "7", "--max-strings", "8", "--max-string-l", "9", "--man", "m"},
		{"--timeout", "1", "--input", "in", "--output", "out", "--manifest-cli", "m", "--max-strings", "8", "--timeout", "7", "--max-string-len", " +9 "},
	}
	for _, args := range cases {
		o, code, done, out, errText := parse(args, 78)
		if done || code != 0 || out != "" || errText != "" {
			t.Fatalf("%v: done=%v code=%d stdout=%q stderr=%q", args, done, code, out, errText)
		}
		if o.input != "in" || o.output != "out" || o.manifestCLI != "m" ||
			o.timeout.String() != "7" || o.maxStrings.String() != "8" || o.maxStringLen.String() != "9" {
			t.Fatalf("%v: parsed %+v", args, o)
		}
	}
}

func TestParseArgsDefaults(t *testing.T) {
	o, _, done, _, _ := parse([]string{"--input", "i", "--output", "o", "--manifest-cli", "m"}, 78)
	if done || o.timeout.String() != "120" || o.maxStrings.String() != "2000" || o.maxStringLen.String() != "256" {
		t.Fatalf("defaults: %+v done=%v", o, done)
	}
}

func TestParseArgsIntegersFollowPython(t *testing.T) {
	good := map[string]string{"5": "5", "-5": "-5", "+5": "5", " 5\n": "5", "1_000": "1000", "007": "7", "-0": "0", "٣": "3", "１２": "12"}
	for in, want := range good {
		o, _, done, _, errText := parse([]string{"--timeout", in, "--input", "i", "--output", "o", "--manifest-cli", "m"}, 78)
		if done || o.timeout.String() != want {
			t.Errorf("--timeout %q: got %v done=%v stderr=%q, want %s", in, o.timeout, done, errText, want)
		}
	}
	for _, bad := range []string{"", "1__0", "_1", "1_", "0x10", "1.5", "1e3", strings.Repeat("9", 4301)} {
		_, code, done, _, errText := parse([]string{"--timeout", bad, "--input", "i", "--output", "o", "--manifest-cli", "m"}, 78)
		if !done || code != 2 || !strings.Contains(errText, "argument --timeout: invalid int value: ") {
			t.Errorf("--timeout %q: done=%v code=%d stderr=%q", bad, done, code, errText)
		}
	}
	big := strings.Repeat("9", 40)
	o, _, done, _, _ := parse([]string{"--timeout", big, "--input", "i", "--output", "o", "--manifest-cli", "m"}, 78)
	if done || o.timeout.String() != big {
		t.Errorf("a 40 digit timeout must be kept exactly, got %v", o.timeout)
	}
}

func TestParseArgsPathsAreNormalizedLikePathlib(t *testing.T) {
	cases := map[string]string{"a//b/./c/": "a/b/c", "": ".", ".": ".", "./": ".", "/": "/", "//x": "//x", "///x": "/x", "/a/../b": "/a/../b", "a/": "a"}
	for in, want := range cases {
		o, _, done, _, errText := parse([]string{"--input", in, "--output", in, "--manifest-cli", in}, 78)
		if done || o.input != want || o.output != want || o.manifestCLI != want {
			t.Errorf("%q: got %q %q %q (done=%v %s), want %q", in, o.input, o.output, o.manifestCLI, done, errText, want)
		}
	}
}
