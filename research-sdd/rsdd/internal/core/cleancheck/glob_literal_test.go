package cleancheck

import "testing"

// An unterminated bracket is literal text in every shape, and `[[:]` is the set of `[` and `:`. Bash 5 agrees on
// the first rows and answers no-match on the others (each bash answer below was read off
// `[[ s == pattern ]]`); the matcher keeps the uniform rule. Declared in tool-registry.d/clean-check.md.
func TestGlobMatchUnterminatedBracketIsLiteral(t *testing.T) {
	cases := []struct {
		pattern, s string
		want       bool
		bash       string
	}{
		{"[", "[", true, "y"},
		{"[a", "[a", true, "y"},
		{"[a-c-", "[a-c-", true, "y"},
		{"[[:]", ":", true, "y"},
		{"[[:]", "a", false, "n"},
		{"[a-", "[a-", true, "n"},
		{"[!a-", "[!a-", true, "n"},
		{`[\`, `[\`, true, "n"},
		{`[a\`, `[a\`, true, "n"},
		{`[]\`, `[]\`, true, "n"},
		{"[[:]", "[", true, "n"},
		{"[a-", "a", false, "n"},
		{`[\`, "[", false, "n"},
	}
	for _, c := range cases {
		if got := globMatch(c.pattern, c.s); got != c.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v (bash answers %s)", c.pattern, c.s, got, c.want, c.bash)
		}
	}
}
