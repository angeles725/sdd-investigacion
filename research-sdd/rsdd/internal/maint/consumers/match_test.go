package consumers

import "testing"

func TestWholeNameBoundaries(t *testing.T) {
	names := map[string]bool{"foo.sh": true, "a.js": true, "a.js.map": true}
	cases := []struct {
		name, in string
		want     map[string]int
	}{
		{"the whole file", "foo.sh", map[string]int{"foo.sh": 1}},
		{"at the very end after a newline", "x\nfoo.sh", map[string]int{"foo.sh": 1}},
		{"at the very start", "foo.sh run", map[string]int{"foo.sh": 1}},
		{"preceded by a letter", "afoo.sh", nil},
		{"preceded by a digit", "1foo.sh", nil},
		{"preceded by an underscore", "_foo.sh", nil},
		{"preceded by a dot", ".foo.sh", nil},
		{"preceded by a dash", "-foo.sh", nil},
		{"preceded by the last lower-case letter", "zfoo.sh", nil},
		{"preceded by the first upper-case letter", "Afoo.sh", nil},
		{"preceded by the last upper-case letter", "Zfoo.sh", nil},
		{"preceded by the first digit", "0foo.sh", nil},
		{"preceded by the last digit", "9foo.sh", nil},
		{"preceded by the characters next to each range", "`foo.sh {foo.sh @foo.sh [foo.sh /foo.sh :foo.sh", map[string]int{"foo.sh": 6}},
		{"preceded by a slash", "dir/foo.sh", map[string]int{"foo.sh": 1}},
		{"preceded by a space, a quote, a paren, a tab, an equals sign", " foo.sh \"foo.sh\" (foo.sh)\tfoo.sh =foo.sh", map[string]int{"foo.sh": 5}},
		{"preceded by a non-ASCII letter", "éfoo.sh", map[string]int{"foo.sh": 1}},
		{"followed by a letter", "foo.sha", nil},
		{"followed by a digit", "foo.sh1", nil},
		{"followed by the first and last lower-case letter", "foo.sha foo.shz", nil},
		{"followed by the first and last upper-case letter", "foo.shA foo.shZ", nil},
		{"followed by the first and last digit", "foo.sh0 foo.sh9", nil},
		{"followed by the characters next to each range", "foo.sh` foo.sh{ foo.sh@ foo.sh[ foo.sh/ foo.sh:", map[string]int{"foo.sh": 6}},
		{"followed by a dot and the edge of each range", "foo.sh.a foo.sh.z foo.sh.A foo.sh.Z foo.sh.0 foo.sh.9", nil},
		{"followed by an underscore", "foo.sh_x", nil},
		{"followed by a dash", "foo.sh-x", nil},
		{"followed by a dot and a letter", "foo.sh.bak", nil},
		{"followed by a dot and a digit", "foo.sh.1", nil},
		{"followed by a dot at the end of the file", "see foo.sh.", map[string]int{"foo.sh": 1}},
		{"followed by a dot at the end of a sentence", "see foo.sh. Next", map[string]int{"foo.sh": 1}},
		{"followed by a dot and a dash", "foo.sh.-", map[string]int{"foo.sh": 1}},
		{"followed by two dots", "foo.sh..", map[string]int{"foo.sh": 1}},
		{"followed by punctuation", "foo.sh, foo.sh) foo.sh/ foo.sh:", map[string]int{"foo.sh": 4}},
		{"two occurrences", "foo.sh foo.sh", map[string]int{"foo.sh": 2}},
		{"a longer live name that starts with a live name", "a.js.map", map[string]int{"a.js.map": 1}},
		{"the shorter live name next to the longer", "a.js a.js.map a.js.", map[string]int{"a.js": 2, "a.js.map": 1}},
		{"a name inside another path component", "my-foo.sh dir.foo.sh", nil},
		{"nothing", "", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := countNames([]byte(c.in), names)
			if len(got) != len(c.want) {
				t.Fatalf("countNames(%q) = %v, want %v", c.in, got, c.want)
			}
			for k, v := range c.want {
				if got[k] != v {
					t.Fatalf("countNames(%q) = %v, want %v", c.in, got, c.want)
				}
			}
		})
	}
}
