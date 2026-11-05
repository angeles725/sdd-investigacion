package stageissues

import "testing"

// Mutation-killing unit tests of rows.go (kit issue #2592): the header-role reader and the cell helpers.

func TestHeaderRolesPositionalFallback(t *testing.T) {
	for _, c := range []struct {
		name, header       string
		ct, cg, ce, cy, cp int
	}{
		{"no title column: positional reading", "| # | Foo | Bar | Baz |", 0, 0, 0, 0, 0},
		{"title only", "| # | change |", 2, 0, 0, 0, 0},
		{"3 cells fill the target", "| # | change | foo |", 2, 3, 0, 0, 0},
		{"4 cells fill the evidence", "| # | change | foo | bar |", 2, 3, 4, 0, 0},
		{"5 cells fill the type", "| # | change | foo | bar | baz |", 2, 3, 4, 5, 0},
		{"6 cells fill the priority", "| # | change | foo | bar | baz | qux |", 2, 3, 4, 5, 6},
		{"a claimed column is not reused", "| # | change | type |", 2, 0, 0, 3, 0},
		{"named target wins over its positional column", "| # | change | foo | target |", 2, 4, 0, 0, 0},
		{"named evidence wins over its positional column", "| # | change | foo | bar | evidence |", 2, 3, 5, 0, 0},
		{"named type wins over its positional column", "| # | change | a | b | c | type |", 2, 3, 4, 6, 0},
		{"named priority wins over its positional column", "| # | change | a | b | c | d | priority |", 2, 3, 4, 5, 7},
	} {
		ct, cg, ce, cy, cp := headerRoles(c.header)
		if ct != c.ct || cg != c.cg || ce != c.ce || cy != c.cy || cp != c.cp {
			t.Errorf("%s: headerRoles(%q) = %d %d %d %d %d, want %d %d %d %d %d", c.name, c.header, ct, cg, ce, cy, cp, c.ct, c.cg, c.ce, c.cy, c.cp)
		}
	}
}

func TestRemoveSpaceDropsOnlyCSpace(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a \t\n\v\f\rb", "ab"},
		{" ", ""},
		{"\u0080  é ", "\u0080 é "}, // non-ASCII blanks are kept
	} {
		if got := removeSpace(c.in); got != c.want {
			t.Errorf("removeSpace(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if got := stripSpaceLower(" Doc Fix\t"); got != "docfix" {
		t.Errorf("stripSpaceLower = %q", got)
	}
	if got := mapType("Doc Fix"); got != "docs" {
		t.Errorf("mapType(\"Doc Fix\") = %q, want docs", got)
	}
	if got := mapPriority("Hi gh"); got != "high" {
		t.Errorf("mapPriority(\"Hi gh\") = %q, want high", got)
	}
}
