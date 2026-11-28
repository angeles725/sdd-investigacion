package console

import (
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// stdioWith is a Stdio whose environment is exactly kv.
func stdioWith(kv map[string]string) cli.Stdio {
	return cli.Stdio{Env: func(k string) string { return kv[k] }, Clock: time.Now}
}

const (
	cLocale    = "C"
	utf8Locale = "C.UTF-8"
)

func envFor(locale string) *env { return newEnv(stdioWith(map[string]string{"LC_ALL": locale})) }

// Every expectation below is what GNU coreutils 9.4 printed for the same name (mkdir -p and tee on a read-only
// directory), captured when the port was written; the live legacy script is compared with the port for several of
// them by TestDifferential.
func TestQuoteCMatchesMkdir(t *testing.T) {
	cases := []struct{ locale, in, want string }{
		{cLocale, "ro/plain", `'ro/plain'`},
		{cLocale, "ro/it's", `'ro/it\'s'`},
		{cLocale, `ro/a\b`, `'ro/a\\b'`},
		{cLocale, "ro/tab\tx", `'ro/tab\tx'`},
		{cLocale, "ro/nl\nx", `'ro/nl\nx'`},
		{cLocale, "ro/\a\b\v\f\r", `'ro/\a\b\v\f\r'`},
		{cLocale, "ro/ü", `'ro/\303\274'`},
		{cLocale, "ro/$x q\"d", `'ro/$x q"d'`},
		{cLocale, "\x01", `'\001'`},
		{cLocale, "del\x7fx", `'del\177x'`},
		{cLocale, "", `''`},
		{utf8Locale, "ro/it's", `‘ro/it's’`},
		{utf8Locale, "ro/ü x", `‘ro/ü x’`},
		{utf8Locale, "ro/bad\xffbyte", `‘ro/bad\377byte’`},
		{utf8Locale, "ro/‘x’", `‘ro/‘x\’’`},
		{utf8Locale, "ro/del\x7fx", `‘ro/del\177x’`},
		{utf8Locale, "ro/tab\tx", `‘ro/tab\tx’`},
		{utf8Locale, `ro/a\b`, `‘ro/a\\b’`},
		{utf8Locale, "ro/\u0085x", `‘ro/\302\205x’`}, // a C1 control is not printable
		{cLocale, "ro/\x80x", `'ro/\200x'`},
		{utf8Locale, "ro/\x80x", `‘ro/\200x’`}, // a lone continuation byte starts no character
		{utf8Locale, "ro/\xc3", `‘ro/\303’`},   // a truncated sequence
	}
	for _, c := range cases {
		if got := envFor(c.locale).quoteC(c.in); got != c.want {
			t.Errorf("quoteC(%q) in %s = %s, want %s", c.in, c.locale, got, c.want)
		}
	}
}

func TestQuoteShellMatchesTee(t *testing.T) {
	cases := []struct{ locale, in, want string }{
		{cLocale, "ro2/plain-name_1.txt", `ro2/plain-name_1.txt`},
		{cLocale, "ro2/#h", `ro2/#h`},
		{cLocale, "ro2/{x}", `ro2/{x}`},
		{cLocale, "ro2/a,b+c%d@e]f~", `ro2/a,b+c%d@e]f~`},
		{cLocale, "#h", `'#h'`},
		{cLocale, "~tilde/x", `'~tilde/x'`},
		{cLocale, "{", `'{'`},
		{cLocale, "ro2/a b", `'ro2/a b'`},
		{cLocale, "ro2/a=b", `'ro2/a=b'`},
		{cLocale, "ro2/a:b", `'ro2/a:b'`},
		{cLocale, "ro2/*", `'ro2/*'`},
		{cLocale, "ro2/$x", `'ro2/$x'`},
		{cLocale, "ro2/a`b", "'ro2/a`b'"},
		{cLocale, `ro2/a\b`, `'ro2/a\b'`},
		{cLocale, `ro2/a"b`, `'ro2/a"b'`},
		{cLocale, "ro2/it's", `"ro2/it's"`},
		{cLocale, "ro2/'", `"ro2/'"`},
		{cLocale, "ro2/a''b", `"ro2/a''b"`},
		{cLocale, "ro2/a'b c", `"ro2/a'b c"`},
		{cLocale, `ro2/a"b'c`, `'ro2/a"b'\''c'`},
		{cLocale, "ro2/a'b$c", `'ro2/a'\''b$c'`},
		{cLocale, `ro2/a'b\c`, `'ro2/a'\''b\c'`},
		{cLocale, "ro2/ü", `'ro2/'$'\303\274'`},
		{cLocale, "ro2/é'x", `'ro2/'$'\303\251'\''x'`},
		{cLocale, "ro2/\x01", `'ro2/'$'\001'`},
		{cLocale, "ro2/nl\nx", `'ro2/nl'$'\n''x'`},
		{cLocale, "ro2/tab\tx", `'ro2/tab'$'\t''x'`},
		{cLocale, "ro2/x\x7f", `'ro2/x'$'\177'`},
		{utf8Locale, "ro2/ü", `ro2/ü`},
		{utf8Locale, "ro2/ü x", `'ro2/ü x'`},
		{utf8Locale, "ro2/ü'x", `"ro2/ü'x"`},
		{utf8Locale, "ro2/bad\xffbyte", `'ro2/bad'$'\377''byte'`},
		{utf8Locale, "ro2/\u0085x", `'ro2/'$'\302\205''x'`},
		{cLocale, "ro2/\x80x", `'ro2/'$'\200''x'`},
		{utf8Locale, "ro2/\x80x", `'ro2/'$'\200''x'`},
		{utf8Locale, "ro2/\xc3", `'ro2/'$'\303'`},
	}
	for _, c := range cases {
		if got := envFor(c.locale).quoteShell(c.in); got != c.want {
			t.Errorf("quoteShell(%q) in %s = %s, want %s", c.in, c.locale, got, c.want)
		}
	}
}

func TestUTF8LocaleFollowsTheCategoryPrecedence(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want bool
	}{
		{"nothing set", nil, false},
		{"LC_ALL wins over everything", map[string]string{"LC_ALL": "C", "LC_CTYPE": "C.UTF-8", "LANG": "C.UTF-8"}, false},
		{"LC_ALL names UTF-8", map[string]string{"LC_ALL": "C.UTF-8"}, true},
		{"LC_CTYPE wins over LANG", map[string]string{"LC_CTYPE": "C.UTF-8", "LANG": "C"}, true},
		{"LC_CTYPE C beats a UTF-8 LANG", map[string]string{"LC_CTYPE": "C", "LANG": "C.UTF-8"}, false},
		{"LANG alone", map[string]string{"LANG": "en_US.UTF-8"}, true},
		{"utf8 spelling", map[string]string{"LANG": "en_US.utf8"}, true},
		{"modifier after the codeset", map[string]string{"LANG": "de_DE.UTF-8@euro"}, true},
		{"a modifier is not the codeset", map[string]string{"LANG": "de_DE@euro"}, false},
		{"an empty LC_ALL is unset", map[string]string{"LC_ALL": "", "LANG": "C.UTF-8"}, true},
		{"latin1", map[string]string{"LANG": "en_US.ISO-8859-1"}, false},
		{"no codeset", map[string]string{"LANG": "en_US"}, false},
	}
	for _, c := range cases {
		if got := newEnv(stdioWith(c.env)).utf8Locale(); got != c.want {
			t.Errorf("%s: utf8Locale = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPortAndBaudPredicates(t *testing.T) {
	for _, s := range []string{"COM0", "COM9", "COM10", "COM99"} {
		if !isComPort(s) {
			t.Errorf("isComPort(%q) = false", s)
		}
	}
	for _, s := range []string{"", "COM", "COM100", "com3", "COM-1", "COM1x", "XCOM3", "COM3 ", "COM٣", "OOM12"} {
		if isComPort(s) {
			t.Errorf("isComPort(%q) = true", s)
		}
	}
	for _, s := range []string{"0", "007", "115200", strings.Repeat("9", 40)} {
		if !isDecimal(s) {
			t.Errorf("isDecimal(%q) = false", s)
		}
	}
	for _, s := range []string{"", "-1", "1.5", "+1", "12a", " 1", "٣"} {
		if isDecimal(s) {
			t.Errorf("isDecimal(%q) = true", s)
		}
	}
}
