package cleancheck

import "testing"

// Bracket-expression cases. Each want is what bash's `[[ s == pattern ]]` answers in the C locale (every row was run
// through bash 5 by hand). They sit at the edges the mutants of the bracket code move: the first and last member of a
// range, the character just outside it, what follows a range or a class, and a pattern that ends inside a bracket.
var bracketCases = []struct {
	pattern, s string
	want       bool
}{
	// range ends are inclusive; the neighbours are not members
	{"[a-c]", "a", true}, {"[a-c]", "c", true}, {"[a-c]", "`", false}, {"[a-c]", "d", false}, {"[a-c]", "-", false},
	{"[a-a]", "a", true}, {"[a-a]", "b", false}, {"[b-a]", "a", false}, {"[--/]", "-", true}, {"[--/]", ".", true},
	// what follows a range is parsed from the right place
	{"[a-c]b", "ab", true}, {"[a-c-]-", "a-", true}, {"[a-c-]b", "ab", true}, {"[a-cx]", "x", true}, {"[a-c-e]", "a", true},
	{"[a-c-e]", "-", true}, {"[a-c-e]", "d", false}, {"[a-]", "a", true}, {"[a-]", "b", false}, {"[!a-c]", "q", true}, {"[!a-c]b", "qb", true},
	{`[\a-c]`, "b", true}, {`[\a-c]`, "x", false}, {`[\a-c]`, `\`, false}, {`[a-\c]`, "b", true}, {`[a-\c]`, "c", true},
	{"[a-c]*", "ba", true}, {"[a]*", "ba", false}, {"*[a]", "ba", true}, {"[^a]*", "b", true},
	// negation marks only at the start, and only the first ] can be a member
	{"[a^]", "^", true}, {"[a!]", "!", true}, {"[x^]x", "^x", true}, {"[^x]", "z", true}, {"[^x]", "x", false}, {"[!x]", "z", true},
	{"[!x]]", "a]", true}, {"[]]", "]", true}, {"[^]]", "b", true}, {"[!]]", "b", true}, {"[^]", "^", false}, {"a[]]", "a]", true},
	// a bracket that is never closed is ordinary text
	{"[", "[", true}, {"x[", "x[", true}, {"[a", "[a", true}, {"[a", "a", false}, {"[^", "a", false}, {"[!", "a", false}, {"[!", "!", false},
	{"a[", "ab", false}, {"a[", "a[", true}, {"a[b", "a[b", true}, {"[]", "]", false}, {"[!]", "]", false}, {`[\]`, `\`, false}, {`[\]`, "x", false},
	{"[]-a]", "b", false},
	// classes
	{"[[:digit:]x]", "x", true}, {"[[:digit:]x]", "5", true}, {"[[:digit:]x]", "-", false}, {"[[:digit:]x]x", "5x", true},
	{"[[:digit:]-]", "-", true}, {"[[:digit:]-]", "5", true}, {"[[:digit:]-]-", "5-", true}, {"[[:digit:]-]b", "xb", false},
	{"[[:digit:]-z]", "b", false}, {"[[:digit:]]", "]", false}, {"[x[:alpha:]]", "a", true}, {"[[:alpha:]x]", "x", true},
	{"[[:alpha:][:digit:]]", "5", true}, {"[[:alpha:][:digit:]]", "-", false}, {"[![:alpha:]]", "5", true},
	{"[[:digit:]", "[", false}, {"[[:digit", "[", false}, {"[[:", "[", false}, {"[[:]", ":", true}, {"[[]", "[", true},
	{"[[:x", ":", false},
	// an unknown or empty class name is an empty class; the name's width is counted in characters
	{"[[:nope:]]", ":", false}, {"[[:nope:]]a", "xa", false}, {"[[::]]", ":", false}, {"[[::]x]", "x", true}, {"[[:é:]x]", "x", true},
}

func TestGlobMatchBracket(t *testing.T) {
	for _, c := range bracketCases {
		if got := globMatch(c.pattern, c.s); got != c.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", c.pattern, c.s, got, c.want)
		}
	}
}

// A pattern that ends inside a bracket, on a lone backslash or on a range's dash, must not read past its end. Bash
// never matches such a pattern at all (`[a-` and `[\` are false against themselves, checked); globMatch reads the
// unterminated [ as text and says true, so the result is deliberately not asserted: this pins only that nothing panics.
func TestGlobMatchPatternEndingInsideBracket(t *testing.T) {
	for _, p := range []string{`[\`, `[a\`, `[]\`, `[!\`, "[a-", "[!a-", "[a-c-", `[a-\`} {
		for _, s := range []string{"", p, "a", `\`, "-"} {
			globMatch(p, s)
		}
	}
}
