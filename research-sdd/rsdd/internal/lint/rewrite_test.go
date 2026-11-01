package lint

import (
	"io/fs"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// Each regex lookaround / Unicode class of lint_block.py was rewritten as code or an explicit class. These tests pin
// every rewrite with a match, a non-match and the edges; expectations come from Python's `re` (checked against the
// frozen lint_block.py when they were written, and again by the differential corpus).

func TestLintBlockR6ClaimRewrite(t *testing.T) {
	pad := func(n int) string { return strings.Repeat(" ", n) }
	for _, c := range []struct {
		name, text, hit string
		ok              bool
	}{
		{"plain", "[Block 3] never shows x", "[Block 3] never shows", true},
		{"dot then non-space is a filler (lookahead)", "[Block 3] a.b never shows", "[Block 3] a.b never shows", true},
		{"dot then space ends the clause", "[Block 3] a. never shows", "", false},
		{"dot directly before the verdict", "[Block 3] a.never shows", "[Block 3] a.never shows", true},
		{"dot at the very end", "[Block 3] a.", "", false},
		{"dot then end then nothing", "[Block 3] never shows.", "[Block 3] never shows", true},
		{"two dots", "[Block 3] a..never shows", "[Block 3] a..never shows", true},
		{"dot then nbsp is a boundary", "[Block 3] a.\u00a0never shows", "", false},
		{"exactly 80 fillers", "[Block 3]" + pad(80) + "never shows", "[Block 3]" + pad(80) + "never shows", true},
		{"81 fillers", "[Block 3]" + pad(81) + "never shows", "", false},
		{"80 multibyte fillers count runes", "[Block 3]" + strings.Repeat("é", 79) + " never shows", "[Block 3]" + strings.Repeat("é", 79) + " never shows", true},
		{"81 multibyte fillers", "[Block 3]" + strings.Repeat("é", 80) + " never shows", "", false},
		{"word char before verdict (leading \\b)", "[Block 3] xnever shows", "", false},
		{"underscore before verdict", "[Block 3] _never shows", "", false},
		{"unicode letter before verdict", "[Block 3] énever shows", "", false},
		{"unicode digit before verdict", "[Block 3] ٣never shows", "", false},
		{"punctuation before verdict", "[Block 3](never shows", "[Block 3](never shows", true},
		{"verdict glued to the bracket", "[Block 3]never shows", "[Block 3]never shows", true},
		{"trailing \\b: extra letter", "[Block 3] never showsx", "", false},
		{"trailing \\b: unicode letter", "[Block 3] never showsé", "", false},
		{"trailing \\b: underscore", "[Block 3] never shows_", "", false},
		{"trailing \\b: shown is not a form", "[Block 3] never shown", "", false},
		{"suffix s", "[Block 3] never mentions it", "[Block 3] never mentions", true},
		{"suffix ed", "[Block 3] never mentioned it", "[Block 3] never mentioned", true},
		{"suffix d", "[Block 3] never cited it", "[Block 3] never cited", true},
		{"suffix d on include", "[Block 3] never included", "[Block 3] never included", true},
		{"no suffix at the end", "[Block 3] never contain", "[Block 3] never contain", true},
		{"suffix then punctuation", "[Block 3] never cites, ever", "[Block 3] never cites", true},
		{"semicolon blocks", "[Block 3] a; never shows", "", false},
		{"em dash blocks", "[Block 3] — never shows", "", false},
		{"en dash blocks", "[Block 3] – never shows", "", false},
		{"hyphen does not block", "[Block 3] - never shows", "[Block 3] - never shows", true},
		{"ignore case", "[BLOCK 3] NEVER SHOWS", "[BLOCK 3] NEVER SHOWS", true},
		{"no space after Block", "[Block3] never shows", "[Block3] never shows", true},
		{"nbsp after Block", "[Block\u00a03] never shows", "[Block\u00a03] never shows", true},
		{"unicode digit number", "[Block ٣] never cites", "[Block ٣] never cites", true},
		{"does not", "[Block 3] does not show", "[Block 3] does not show", true},
		{"did not", "[Block 3] did not show", "[Block 3] did not show", true},
		{"do not", "[Block 3] do not show", "[Block 3] do not show", true},
		{"doesn't", "[Block 3] doesn't show", "[Block 3] doesn't show", true},
		{"didn't", "[Block 3] didn't show", "[Block 3] didn't show", true},
		{"nbsp inside does not", "[Block 3] does\u00a0not show", "[Block 3] does\u00a0not show", true},
		{"glued not", "[Block 3] does notshow", "", false},
		{"wrong verb", "[Block 3] never references it", "", false},
		{"second block rescues the first", "[Block 1] x. [Block 2] never shows", "[Block 2] never shows", true},
		{"no block", "never shows", "", false},
		{"unterminated block", "[Block 3 never shows", "", false},
		{"lazy: first verdict wins", "[Block 3] never shows and never cites", "[Block 3] never shows", true},
	} {
		hit, ok := r6Claim(c.text)
		if ok != c.ok || hit != c.hit {
			t.Errorf("%s: r6Claim(%q) = %q, %v; want %q, %v", c.name, c.text, hit, ok, c.hit, c.ok)
		}
	}
}

func TestLintBlockWaiverBodyRewrite(t *testing.T) {
	for _, c := range []struct {
		in, id, rest string
		ok           bool
	}{
		{" R3 reason=x", "R3", "reason=x", true},
		{"r3 free", "r3", "free", true},
		{"R12 reason=x", "R12", "reason=x", true},
		{"R3", "R3", "", true},
		{"R3   ", "R3", "", true},
		{"R3\u00a0reason=x", "R3", "reason=x", true},
		{"\u2003R3\u3000reason=x", "R3", "reason=x", true},
		{"R3\nreason=x", "R3", "reason=x", true},
		{"R٣ x", "R٣", "x", true},
		{"R12abc reason=x", "", "", false},
		{"R3_ x", "", "", false},
		{"R3é x", "", "", false},
		{"R3٣ x", "R3٣", "x", true},
		{"R1 R2 x", "R1", "R2 x", true},
		{"R", "", "", false},
		{"RR3 x", "", "", false},
		{"reason=x", "", "", false},
		{"", "", "", false},
	} {
		id, rest, ok := waiverBody(c.in)
		if id != c.id || rest != c.rest || ok != c.ok {
			t.Errorf("waiverBody(%q) = %q, %q, %v; want %q, %q, %v", c.in, id, rest, ok, c.id, c.rest, c.ok)
		}
	}
}

func TestLintBlockBlockfileTokenRewrite(t *testing.T) {
	for tok, want := range map[string]bool{
		"demo-block12.md":          true,
		"demo-bloque3-x_y.md":      true,
		"demo-block12.md,":         true,
		"demo-block12.md.bak":      true, // `.md` is followed by `.`: a boundary
		"demo-block12.mdx":         false,
		"demo-block12.md_x":        false,
		"demo-block12.mdé":         false,
		"demo-block12.md٣":         false,
		"block12.md":               false, // needs `<target>-`
		"demo-blockx.md":           false,
		"evidence/":                true,
		"binary/sha256":            false,
		"3/3":                      false,
		"N/A":                      false,
		"out.txt:12":               false,
		"dir/out.txt:12":           true,
		"dir/out.txt:12-20":        true,
		"dir/out.txt:":             true, // trailing colon is stripped first
		"a/b/c":                    false,
		"a/b.c/d":                  true,
		"N4.14/N5.0":               false,
		"/tmp/x.txt":               false,
		"dir//":                    true,
		"/":                        false,
		"a/b.123":                  false, // an extension needs a letter
		"a/b.1a":                   true,
		"a/b.toolongext":           true, // 10 letters fit {0,5}+1+{0,5}
		"a/b.waytoolongextension":  false,
		"a/٣٣.md":                  true,
		"$TMPDIR/x/y.txt":          false,
		"scratchpad/x.txt":         false,
		"x/y.txt;":                 true,
		"demo-block12.md/..//tmp/": false,
	} {
		if got := isDurableToken(tok); got != want {
			t.Errorf("isDurableToken(%q) = %v, want %v", tok, got, want)
		}
	}
}

func TestLintBlockUnicodeClassRewrite(t *testing.T) {
	// `\s` of a Python str pattern is str.isspace(): the ASCII set plus \v, \x1c-\x1f, \x85, \xa0 and the Zs/Zl/Zp runes.
	for _, r := range "\t\n\v\f\r\x1c\x1d\x1e\x1f \u0085\u00a0\u1680\u2000\u200a\u2028\u2029\u202f\u205f\u3000" {
		if !isPySpace(r) || !ws2.MatchString(string(r)) {
			t.Errorf("U+%04X must be whitespace (func=%v class=%v)", r, isPySpace(r), ws2.MatchString(string(r)))
		}
	}
	for _, r := range "a_0\u180e\u200b\u2007xé" {
		if r == '\u2007' {
			continue // U+2007 is in the \u2000-\u200a run: whitespace
		}
		if isPySpace(r) || ws2.MatchString(string(r)) {
			t.Errorf("U+%04X must not be whitespace", r)
		}
	}
	for title, want := range map[string]string{"\u00a0## T": "T", "#\u00a0T": "T", "#\u2003": "", "#": "", "#1": "!", "#hashtag": "!", "####### x": "!", "\v## T": "T"} {
		got, ok := headingTitle(title)
		if want == "!" {
			if ok {
				t.Errorf("headingTitle(%q) matched", title)
			}
			continue
		}
		if !ok || got != want {
			t.Errorf("headingTitle(%q) = %q, %v; want %q", title, got, ok, want)
		}
	}
	if !listItemRE.MatchString("٣. item") || !listItemRE.MatchString("\u00a0- x") || listItemRE.MatchString("-x") || listItemRE.MatchString("1) x") {
		t.Errorf("list item recognition (unicode digits, nbsp lead, glued dash, paren) is wrong")
	}
	if got := dequote("\u00a0> \u00a0text"); got != "\u00a0text" {
		t.Errorf("dequote removes one whitespace after the marker only: %q", got)
	}
}

// One assertion per alternative / bound of the regex literals (values from Python's `re` on the frozen lint_block.py).
func TestLintBlockRegexLiteralPins(t *testing.T) {
	for _, s := range []string{"/tmp/x", "/var/tmp/x", "/private/tmp/x", "/dev/shm/x", "$TMPDIR", "${TMPDIR}", "$TMPDIR}", "${TMPDIR", "scratchpad", "SCRATCHPAD"} {
		if !r3EphemeralRE.MatchString(s) {
			t.Errorf("ephemeral location %q not recognised", s)
		}
	}
	for _, s := range []string{"/tmpx", "/dev/shmx", "tmp/x", "$"} {
		if r3EphemeralRE.MatchString(s) {
			t.Errorf("%q is not an ephemeral location", s)
		}
	}
	if got := r3TokenRE.FindAllString("a(b)c'd\"e`f g\u00a0h\u2003i", -1); !reflect.DeepEqual(got, []string{"a", "b", "c", "d", "e", "f", "g", "h", "i"}) {
		t.Errorf("tokenisation splits on parens, quotes, backtick and unicode space: %q", got)
	}
	for s, want := range map[string]bool{"\u00a0| a |\u00a0": true, "| a |": true, "|| ": false, "|||": true, "x| a |": false, "\u2003|a|\u3000": true} {
		if tableRowRE.MatchString(s) != want {
			t.Errorf("tableRowRE(%q) != %v", s, want)
		}
	}
	for s, want := range map[string]bool{"| :--- | ---: |": true, "|:-:|": true, "|---|": true, "|a|": false, "\u00a0|---|\u00a0": true, "| - |": true} {
		if tableSepRE.MatchString(s) != want {
			t.Errorf("tableSepRE(%q) != %v", s, want)
		}
	}
	for s, want := range map[string]string{"###### six": "six", "####### seven": "!", "# one": "one", "##": "", "#\u00a0x": "x"} {
		got, ok := headingTitle(s)
		if (want == "!") == ok || (ok && got != want) {
			t.Errorf("headingTitle(%q) = %q, %v; want %q", s, got, ok, want)
		}
	}
	for _, c := range []struct {
		lines []string
		want  int // number of fenced lines
	}{
		{[]string{"``", "text"}, 0}, {[]string{"```", "x", "```"}, 3}, {[]string{"~~~", "x"}, 2}, {[]string{"~~", "x"}, 0}, {[]string{"````", "```", "````"}, 3},
	} {
		if f, _ := scanFences(c.lines); len(f) != c.want {
			t.Errorf("scanFences(%q) fenced %d lines, want %d", c.lines, len(f), c.want)
		}
	}
	for tok, want := range map[string]bool{"a/b.elevenchars": true, "a/b.12345a": true, "a/b.123456a": false, "a/b.a12345": true, "a/b.a123456": false, "a/b.12345a12345": true, "a/b.12345a123456": false} {
		if got := isDurableToken(tok); got != want {
			t.Errorf("isDurableToken(%q) = %v, want %v (extension caps 5+1+5)", tok, got, want)
		}
	}
	if id, rest, ok := waiverBody("   R3 x"); !ok || id != "R3" || rest != "x" {
		t.Errorf("waiverBody skips any run of leading whitespace: %q %q %v", id, rest, ok)
	}
	for _, s := range []string{"[Block 3] doesnot show", "[Block 3] didnot show", "[Block 3] donot show"} {
		if hit, ok := r6Claim(s); ok {
			t.Errorf("r6Claim(%q) = %q; the verdict needs whitespace before `not`", s, hit)
		}
	}
	if !r6RawPathRE.MatchString("evidence/") || r6RawPathRE.MatchString("evidence") || !r6RawPathRE.MatchString("a/b.c") || r6RawPathRE.MatchString("a/b") {
		t.Errorf("raw artifact path forms")
	}
}

func TestLintBlockPythonTextHelpers(t *testing.T) {
	if got, want := pySplitLines("a\vb\fc\x1cd\x1de\x1ef\u0085g\u2028h\u2029i\nj"), []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}; !reflect.DeepEqual(got, want) {
		t.Errorf("pySplitLines separators: %q", got)
	}
	for in, want := range map[string][]string{"": nil, "\n": {""}, "a\n": {"a"}, "a\n\nb": {"a", "", "b"}, "a": {"a"}, "\n\n": {"", ""}} {
		if got := pySplitLines(in); !reflect.DeepEqual(got, want) {
			t.Errorf("pySplitLines(%q) = %q, want %q", in, got, want)
		}
	}
	if got := universalNewlines("a\r\nb\rc\n"); got != "a\nb\nc\n" {
		t.Errorf("universalNewlines = %q", got)
	}
	if got := pyStrip("\u00a0\u3000x y\u2028 \x1f"); got != "x y" {
		t.Errorf("pyStrip = %q", got)
	}
	if got := pyExcerpt("a \u00a0\t b\u2003c", 100); got != "a b c" {
		t.Errorf("pyExcerpt collapse = %q", got)
	}
	long := strings.Repeat("é", 150)
	if got := pyExcerpt(long, 100); got != strings.Repeat("é", 99)+"..." {
		t.Errorf("pyExcerpt cuts at 99 runes plus three dots: %q", got)
	}
	if got := pyExcerpt(strings.Repeat("x", 100), 100); got != strings.Repeat("x", 100) {
		t.Errorf("pyExcerpt keeps exactly 100 runes")
	}
	if got := pyExcerpt(strings.Repeat("x", 101), 100); got != strings.Repeat("x", 99)+"..." {
		t.Errorf("pyExcerpt cuts 101 runes")
	}
}

func TestLintBlockUTF8ErrorText(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"ok é中\U0001f600", ""},
		{"\xff", "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte"},
		{"ab\x80", "'utf-8' codec can't decode byte 0x80 in position 2: invalid start byte"},
		{"\xc0\x80", "'utf-8' codec can't decode byte 0xc0 in position 0: invalid start byte"},
		{"\xf5", "'utf-8' codec can't decode byte 0xf5 in position 0: invalid start byte"},
		{"\xc3(", "'utf-8' codec can't decode byte 0xc3 in position 0: invalid continuation byte"},
		{"\xe2\x82(", "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte"},
		{"\xe2(", "'utf-8' codec can't decode byte 0xe2 in position 0: invalid continuation byte"},
		{"\xe0\x80\x80", "'utf-8' codec can't decode byte 0xe0 in position 0: invalid continuation byte"},
		{"\xed\xa0\x80", "'utf-8' codec can't decode byte 0xed in position 0: invalid continuation byte"},
		{"\xf4\x90\x80\x80", "'utf-8' codec can't decode byte 0xf4 in position 0: invalid continuation byte"},
		{"\xf0\x90\x80(", "'utf-8' codec can't decode bytes in position 0-2: invalid continuation byte"},
		{"߿ ࠀ \ud7ff \ue000 \uffff \U00010000 \U0010ffff က", ""}, // every boundary of every lead class is valid
		{"\xc1\xbf", "'utf-8' codec can't decode byte 0xc1 in position 0: invalid start byte"},
		{"\xe0\x9f\xbf", "'utf-8' codec can't decode byte 0xe0 in position 0: invalid continuation byte"},
		{"\xf0\x8f\xbf\xbf", "'utf-8' codec can't decode byte 0xf0 in position 0: invalid continuation byte"},
		{"\xdf", "'utf-8' codec can't decode byte 0xdf in position 0: unexpected end of data"},
		{"\xdf(", "'utf-8' codec can't decode byte 0xdf in position 0: invalid continuation byte"},
		{"\xf3\x80\x80", "'utf-8' codec can't decode bytes in position 0-2: unexpected end of data"},
		{"\xee\x80", "'utf-8' codec can't decode bytes in position 0-1: unexpected end of data"},
		{"\xef\xbf(", "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte"},
		{"\xf4\x8f\xbf(", "'utf-8' codec can't decode bytes in position 0-2: invalid continuation byte"},
		{"\xf1\x80\x80(", "'utf-8' codec can't decode bytes in position 0-2: invalid continuation byte"},
		{"\xe0\xa0(", "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte"},
		{"\xed\x9f(", "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte"},
		{"a\xf2\x80", "'utf-8' codec can't decode bytes in position 1-2: unexpected end of data"},
		{"\xf0\x90\x80\x80\xff", "'utf-8' codec can't decode byte 0xff in position 4: invalid start byte"},
		{"x\xc2", "'utf-8' codec can't decode byte 0xc2 in position 1: unexpected end of data"},
		{"\xe2\x82", "'utf-8' codec can't decode bytes in position 0-1: unexpected end of data"},
		{"\xf0\x90\x80", "'utf-8' codec can't decode bytes in position 0-2: unexpected end of data"},
	} {
		if got := utf8Error([]byte(c.in)); got != c.want {
			t.Errorf("utf8Error(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLintBlockPythonOSErrorText(t *testing.T) {
	pe := func(e syscall.Errno) error { return &fs.PathError{Op: "open", Path: "p", Err: e} }
	for _, c := range []struct {
		err  error
		path string
		want string
	}{
		{pe(syscall.EACCES), "a/b.md", "[Errno 13] Permission denied: 'a/b.md'"},
		{pe(syscall.ENOENT), "x", "[Errno 2] No such file or directory: 'x'"},
		{pe(syscall.EISDIR), "d", "[Errno 21] Is a directory: 'd'"},
		{pe(syscall.ELOOP), "l", "[Errno 40] Too many levels of symbolic links: 'l'"},
		{pe(syscall.EACCES), "it's", `[Errno 13] Permission denied: "it's"`},
		{pe(syscall.EACCES), `it's "q"`, `[Errno 13] Permission denied: 'it\'s "q"'`},
	} {
		if got := pyOSError(c.err, c.path); got != c.want {
			t.Errorf("pyOSError = %q, want %q", got, c.want)
		}
	}
	for in, want := range map[string]string{"a\tb": `'a\tb'`, "a\\b": `'a\\b'`, "\x01": `'\x01'`, "é": "'é'", "\u200b": `'\u200b'`, "\u00ad": `'\xad'`, "\U000e0001": `'\U000e0001'`, "\x7f": `'\x7f'`} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
}
