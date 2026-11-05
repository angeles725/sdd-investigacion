package cleancheck

import "testing"

// Each case is what bash's `[[ s == pattern ]]` answers (checked against bash 5 by hand).
func TestGlobMatch(t *testing.T) {
	for _, c := range []struct {
		pattern, s string
		want       bool
	}{
		{"abc", "abc", true}, {"abc", "abd", false}, {"abc", "ab", false}, {"ab", "abc", false}, {"", "", true}, {"", "a", false},
		{"*", "", true}, {"*", "a/b/c", true}, {"a*", "a", true}, {"a*c", "abbbc", true}, {"a*c", "abbbd", false}, {"*b*", "abc", true},
		{"a*b*c", "aXbXbXc", true}, {"a*b", "aXbXc", false}, {"**", "x", true}, {"a**", "a", true}, {"*a", "ba", true}, {"*a", "bab", false},
		{"?", "a", true}, {"?", "", false}, {"?", "ab", false}, {"a?c", "a/c", true}, {"?*", "x", true}, {"a?", "é", false}, {"?", "é", true},
		{"notes/*.md", "notes/deep/b.md", true}, {"a/*/z", "a/b/c/z", true}, {"a/*/z", "a/z", false},
		{"[abc]", "b", true}, {"[abc]", "d", false}, {"[!abc]", "d", true}, {"[!abc]", "a", false}, {"[^abc]", "d", true}, {"[^abc]", "a", false},
		{"[a-c]", "b", true}, {"[a-c]", "d", false}, {"[a-c]x", "bx", true}, {"[c-a]", "b", false}, {"[a-]", "-", true}, {"[a-]", "a", true},
		{"[]]", "]", true}, {"[]a]", "a", true}, {"[!]]", "x", true}, {"[!]]", "]", false}, {"[a", "[a", true}, {"[a", "a", false},
		{"[[:alpha:]]", "q", true}, {"[[:alpha:]]", "5", false}, {"[[:digit:]]", "5", true}, {"[[:digit:]]", "q", false},
		{"[[:alnum:]]", "5", true}, {"[[:alnum:]]", "q", true}, {"[[:alnum:]]", "-", false},
		{"[[:upper:]]", "Q", true}, {"[[:upper:]]", "q", false}, {"[[:lower:]]", "q", true}, {"[[:lower:]]", "Q", false},
		{"[[:space:]]", " ", true}, {"[[:space:]]", "\n", true}, {"[[:space:]]", "x", false}, {"[[:blank:]]", "\t", true}, {"[[:blank:]]", "\n", false},
		{"[[:punct:]]", "!", true}, {"[[:punct:]]", "a", false}, {"[[:punct:]]", " ", false}, {"[[:xdigit:]]", "f", true}, {"[[:xdigit:]]", "g", false},
		{"[[:nope:]]", ":", false}, {"[[:nope:]]", "n", false}, {"[[:alpha:]x]", "x", true}, {"[x[:digit:]]", "7", true}, {"[![:digit:]]", "a", true}, {"[![:digit:]]", "7", false},
		{`\*`, "*", true}, {`\*`, "a", false}, {`a\?`, "a?", true}, {`a\?`, "ab", false}, {`\a`, "a", true}, {`[\]]`, "]", true}, {`[\-a]`, "-", true},
		{`a\`, `a\`, true}, {`[a\-c]`, "b", false},
		{"q?.dat", "q1.dat", true}, {"q?.dat", "q10.dat", false}, {"*.log", "a/b/c.log", true}, {"*.log", "c.log.txt", false},
		{".research-sdd/keep.txt", ".research-sdd/keep.txt", true}, {"name#hash.txt", "name#hash.txt", true},
	} {
		if got := globMatch(c.pattern, c.s); got != c.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", c.pattern, c.s, got, c.want)
		}
	}
}
