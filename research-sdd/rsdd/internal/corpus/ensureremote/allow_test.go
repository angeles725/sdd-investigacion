package ensureremote

import (
	"strings"
	"testing"
)

// Guard-to-test table (allow list, kit issue #1943):
//
//	unknown directive / missing glob / extra text       TestParseAllowMalformed
//	bracket class, extglob operators                    TestParseAllowMalformed
//	blanket glob (only * ? / . and operator characters) TestParseAllowMalformed
//	absolute path, '..' component                       TestParseAllowMalformed
//	comments, blanks, CR, surrounding blanks accepted   TestParseAllowAccepted
//	glob semantics ('*' crosses '/', '?' is one char)   TestGlobMatch

func TestParseAllowAccepted(t *testing.T) {
	got, bad, why := parseAllow([]byte("# public assets\n\n  allow   licenses/*  \r\n\tallow *.der\nallow x.pem"))
	if bad != 0 || why != "" {
		t.Fatalf("unexpected refusal at line %d: %s", bad, why)
	}
	want := []allowEntry{{"licenses/*", 3}, {"*.der", 4}, {"x.pem", 5}}
	if len(got) != len(want) {
		t.Fatalf("entries = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("entry %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestParseAllowEmpty(t *testing.T) {
	for _, in := range []string{"", "# nothing allowed\n", "\n\n   \n", "  # indented comment\n#x y z\n"} {
		got, bad, why := parseAllow([]byte(in))
		if len(got) != 0 || bad != 0 || why != "" {
			t.Errorf("parseAllow(%q) = %v, %d, %q; want nothing", in, got, bad, why)
		}
	}
}

func TestParseAllowMalformed(t *testing.T) {
	for _, tt := range []struct{ line, why string }{
		{"allow", "'allow' needs a path glob"},
		{"deny x.der", "unknown directive 'deny'"},
		{"frob", "unknown directive 'frob'"},
		{"allow a.der b.der", "exactly one path glob per line (got extra text)"},
		{"allow a.der   b.der   c", "exactly one path glob per line (got extra text)"},
		{"allow *", "blanket glob '*' (needs at least one literal character)"},
		{"allow **/*", "blanket glob '**/*' (needs at least one literal character)"},
		{"allow *.*", "blanket glob '*.*' (needs at least one literal character)"},
		{"allow ../x.der", "'..' component in '../x.der'"},
		{"allow a/../x.der", "'..' component in 'a/../x.der'"},
		{"allow a/..", "'..' component in 'a/..'"},
		{"allow /abs/x.der", "absolute path '/abs/x.der' (use a path relative to the corpus root)"},
		{"allow /../x", "'..' component in '/../x'"},
		{"allow *[!/]", "bracket class in '*[!/]' (a glob may only use '*' and '?')"},
		{"allow [!/]*", "bracket class in '[!/]*' (a glob may only use '*' and '?')"},
		{"allow a[bc].der", "bracket class in 'a[bc].der' (a glob may only use '*' and '?')"},
		{"allow a]", "bracket class in 'a]' (a glob may only use '*' and '?')"},
		{"allow !(zz)", "extglob operator in '!(zz)' (a glob may only use '*' and '?')"},
		{"allow @(*)", "extglob operator in '@(*)' (a glob may only use '*' and '?')"},
		{"allow +(a)", "extglob operator in '+(a)' (a glob may only use '*' and '?')"},
		{"allow ?(x).der", "extglob operator in '?(x).der' (a glob may only use '*' and '?')"},
		{"allow *(x).der", "extglob operator in '*(x).der' (a glob may only use '*' and '?')"},
	} {
		for _, where := range []string{"first", "middle", "last", "single"} {
			var lines []string
			wantLine := 1
			switch where {
			case "first":
				lines = []string{tt.line, "allow pub.der", "# c"}
			case "middle":
				lines, wantLine = []string{"allow pub.der", tt.line, "# c"}, 2
			case "last":
				lines, wantLine = []string{"# c", "allow pub.der", tt.line}, 3
			case "single":
				lines = []string{tt.line}
			}
			_, bad, why := parseAllow([]byte(strings.Join(lines, "\n") + "\n"))
			if bad != wantLine || why != tt.why {
				t.Errorf("%s (%s): got line %d %q, want line %d %q", tt.line, where, bad, why, wantLine, tt.why)
			}
		}
	}
}

// The checks run in a fixed order: the first rule that fires names the line.
func TestParseAllowFirstBadLineWins(t *testing.T) {
	_, bad, why := parseAllow([]byte("allow ok.der\nfrob\nallow *\n"))
	if bad != 2 || why != "unknown directive 'frob'" {
		t.Errorf("got line %d %q", bad, why)
	}
}

func TestGlobMatch(t *testing.T) {
	for _, tt := range []struct {
		glob, path string
		want       bool
	}{
		{"pub.der", "pub.der", true},
		{"pub.der", "dir/pub.der", false},
		{"*.der", "pub.der", true},
		{"*.der", "deep/x/pub.der", true}, // '*' crosses '/', as git's pathspec does
		{"licenses/*", "licenses/lic.txt", true},
		{"licenses/*", "licenses/a/b.txt", true},
		{"licenses/*", "other/licenses/lic.txt", false},
		{"a?c", "abc", true},
		{"a?c", "a/c", true},
		{"a?c", "ac", false},
		{"a?c", "abbc", false},
		{"*", "", true},
		{"a*b*c", "aXbYc", true},
		{"a*b*c", "aXbY", false},
		{"*abc", "xxabcabc", true},
		{"*.der", ".der", true},
		{"*.der", "pub.derx", false},
		{`a\*b`, "a*b", true},
		{`a\*b`, "aXb", false},
		{`a\?b`, "a?b", true},
		{`a\\b`, `a\b`, true},
		{`a\`, `a\`, true},
		{"x", "", false},
	} {
		if got := globMatch(tt.glob, tt.path); got != tt.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", tt.glob, tt.path, got, tt.want)
		}
	}
}
