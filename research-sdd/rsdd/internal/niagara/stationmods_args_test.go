package niagara

import "testing"

const (
	smUsage = "usage: station-modules [-h] --input BOG --install ROOT --output JSON\n"
	smHelp  = smUsage + "\nNiagara N4 station module dependency checker. Read-only: resolves module\n" +
		"aliases and type references from a config.bog and reports missing module-parts\n" +
		"in the install.\n\n" +
		"options:\n" +
		"  -h, --help      show this help message and exit\n" +
		"  --input BOG     config.bog (ZIP-compressed file.xml) or bare XML file\n" +
		"  --install ROOT  Niagara N4 install root directory (contains modules/)\n" +
		"  --output JSON   output JSON evidence file (must not already exist)\n"
)

func smUsageErr(msg string) string { return smUsage + "station-modules: error: " + msg + "\n" }

// smArgTable pins the output of the legacy argparse parser (CPython 3.15, COLUMNS=80) for the argument vectors a
// caller can produce. The parity test runs the same vectors against the frozen script.
func smArgTable() []argCase {
	const (
		missingAll     = "the following arguments are required: --input, --install, --output"
		missingInstOut = "the following arguments are required: --install, --output"
		missingOut     = "the following arguments are required: --output"
		missingIn      = "the following arguments are required: --input"
		oneArgIn       = "argument --input: expected one argument"
		oneArgInst     = "argument --install: expected one argument"
	)
	noFile := func(p string) string { return "station-modules: " + p + ": No such file or directory\n" }
	full := func(extra ...string) []string {
		return append([]string{"--input", "a", "--install", "b", "--output", "c"}, extra...)
	}
	return []argCase{
		{"no arguments", nil, 2, "", smUsageErr(missingAll)},
		{"--help", []string{"--help"}, 0, smHelp, ""},
		{"-h", []string{"-h"}, 0, smHelp, ""},
		{"-h glued to more text", []string{"-hX"}, 0, smHelp, ""},
		{"abbreviated --he", []string{"--he"}, 0, smHelp, ""},
		{"help wins over a later unknown option", []string{"-h", "--bogus"}, 0, smHelp, ""},
		{"help after a complete command line", append(full(), "-h"), 0, smHelp, ""},
		{"input only", []string{"--input", "a"}, 2, "", smUsageErr(missingInstOut)},
		{"input and install", []string{"--input", "a", "--install", "b"}, 2, "", smUsageErr(missingOut)},
		{"install and output", []string{"--install", "b", "--output", "c"}, 2, "", smUsageErr(missingIn)},
		{"input without a value", []string{"--input"}, 2, "", smUsageErr(oneArgIn)},
		{"install without a value", []string{"--input", "a", "--install"}, 2, "", smUsageErr(oneArgInst)},
		{"output without a value", []string{"--input", "a", "--install", "b", "--output"}, 2, "", smUsageErr("argument --output: expected one argument")},
		{"a positional alone: required is reported first", []string{"x"}, 2, "", smUsageErr(missingAll)},
		{"extra positional", full("extra"), 2, "", smUsageErr("unrecognized arguments: extra")},
		{"unknown option alone: required is reported first", []string{"--bogus"}, 2, "", smUsageErr(missingAll)},
		{"unknown option after all three", append([]string{"-x"}, full()...), 2, "", smUsageErr("unrecognized arguments: -x")},
		{"after -- everything is positional", []string{"--", "--input", "a"}, 2, "", smUsageErr(missingAll)},
		{"trailing --", append(full(), "--"), 2, "", smUsageErr("unrecognized arguments: --")},
		{"mixed leftovers keep their order", append(full(), "x", "--bogus", "--", "y"), 2, "", smUsageErr("unrecognized arguments: x --bogus -- y")},
		{"a negative number is a leftover", append(full(), "-5"), 2, "", smUsageErr("unrecognized arguments: -5")},
		{"option as the value of --input", []string{"--input", "-x"}, 2, "", smUsageErr(oneArgIn)},
		{"--install as the value of --input", []string{"--input", "--install", "b"}, 2, "", smUsageErr(oneArgIn)},
		{"-- as the value of --install", []string{"--input", "a", "--install", "--", "--output", "c"}, 2, "", smUsageErr(oneArgInst)},
		{"--help with an explicit value", []string{"--help=x"}, 2, "", smUsageErr("argument -h/--help: ignored explicit argument 'x'")},
		{"-h with an explicit value", []string{"-h=1"}, 2, "", smUsageErr("argument -h/--help: ignored explicit argument '1'")},
		{"ambiguous abbreviation of everything", []string{"--=x"}, 2, "", smUsageErr("ambiguous option: --=x could match --help, --input, --install, --output")},
		{"--i is input or install", []string{"--i", "a"}, 2, "", smUsageErr("ambiguous option: --i could match --input, --install")},
		{"--in= is input or install", []string{"--in=a"}, 2, "", smUsageErr("ambiguous option: --in=a could match --input, --install")},
		{"--inp is input", []string{"--inp", "a", "--ins", "b", "--o", "c"}, 2, "", noFile("a")},
		{"--option=value forms", []string{"--input=a", "--install=b", "--output=c"}, 2, "", noFile("a")},
		{"empty --input= value", []string{"--input=", "--install=b", "--output=c"}, 2, "", noFile("")},
		{"value containing =", []string{"--input=a=b", "--install=b", "--output=c"}, 2, "", noFile("a=b")},
		{"last --input wins", []string{"--input", "first", "--input", "a", "--install", "b", "--output", "c"}, 2, "", noFile("a")},
		{"the values may come in any order", []string{"--output", "c", "--install", "b", "--input", "a"}, 2, "", noFile("a")},
		{"a lone dash is a value", []string{"--input", "-", "--install", "b", "--output", "c"}, 2, "", noFile("-")},
		{"a negative number is a value", []string{"--input", "-5", "--install", "b", "--output", "c"}, 2, "", noFile("-5")},
		{"a value with a space after a dash", []string{"--input", "-x y", "--install", "b", "--output", "c"}, 2, "", noFile("-x y")},
		{"empty-string argument is a positional", []string{""}, 2, "", smUsageErr(missingAll)},
		{"option names are case sensitive", []string{"--INPUT", "a"}, 2, "", smUsageErr(missingAll)},
		{"a single dash long name is unknown", []string{"-input", "a"}, 2, "", smUsageErr(missingAll)},
		{"absent input", []string{"--input", "/definitely/not/here", "--install", "b", "--output", "c"}, 2, "", noFile("/definitely/not/here")},
		{"absent input with a non-UTF-8 name", []string{"--input", "/no/bad\xffname", "--install", "b", "--output", "c"}, 2, "", noFile(`/no/bad\udcffname`)},
	}
}

func TestStationModulesArgumentParsingMatchesArgparse(t *testing.T) {
	for _, tt := range smArgTable() {
		t.Run(tt.name, func(t *testing.T) {
			code, out, errs := runSM(tt.args...)
			if code != tt.code || out != tt.out || errs != tt.err {
				t.Errorf("args %q\n got  code=%d stdout=%q stderr=%q\n want code=%d stdout=%q stderr=%q", tt.args, code, out, errs, tt.code, tt.out, tt.err)
			}
		})
	}
}
