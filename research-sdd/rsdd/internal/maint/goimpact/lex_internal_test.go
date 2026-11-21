package goimpact

import (
	"strings"
	"testing"
)

// render shows tokens as: a word, `[x]` for a separator, `{a|b}` after a word for its substitution bodies,
// `!rest` for an unclosed substitution.
func render(ts []tok) string {
	var p []string
	for _, t := range ts {
		s := t.text
		switch {
		case t.bad != "":
			s = "!" + t.bad
		case t.sep:
			s = "[" + t.text + "]"
		case len(t.subs) != 0:
			s += "{" + strings.Join(t.subs, "|") + "}"
		}
		p = append(p, s)
	}
	return strings.Join(p, " ")
}

func TestLexTokens(t *testing.T) {
	cases := []struct{ in, want string }{
		{"a b", "a b"}, {"a\tb", "a b"}, {"a  b", "a b"}, {"", ""}, {"  ", ""},
		{"a;b", "a [;] b"}, {"a|b", "a [|] b"}, {"a&b", "a [&] b"}, {"a(b", "a [(] b"},
		{"a)b", "a [)] b"}, {"a{b", "a [{] b"}, {"a}b", "a [}] b"},
		{"# c", ""}, {"a # c", "a"}, {"a#b", "a#b"}, {`"#"`, `"#"`}, {"a #", "a"}, {"#", ""},
		{`a\;b`, `a\;b`}, {`a\`, `a\`}, {`\`, `\`}, {`\$(a)`, `\$ [(] a [)]`},
		{`'a b'`, `'a b'`}, {`'a;b'c`, `'a;b'c`}, {`'a`, `'a`}, {`'a\' b`, `'a\' b`}, {`'$(a)'`, `'$(a)'`},
		{`"a b"`, `"a b"`}, {`"a\"b c"`, `"a\"b c"`}, {`"a\`, `"a\`}, {`"a;b"`, `"a;b"`}, {`"a`, `"a`},
		{`"a"b"c d"`, `"a"b"c d"`}, {`"\$(a)"`, `"\$(a)"`}, {`"a\" ; b"`, `"a\" ; b"`},
		{"${a b}c d", "${a b}c d"}, {"${a b", "${a b"}, {"$a", "$a"}, {"$", "$"}, {"a$", "a$"}, {"$x(", "$x [(]"},
		{"$(a b)", "$(){a b}"}, {"x$(a)y", "x$()y{a}"}, {`"$(a)"`, `"$()"{a}`}, {`"x $(a b) y"`, `"x $() y"{a b}`},
		{"$(a) $(b)", "$(){a} $(){b}"}, {"$(a)$(b)", "$()$(){a|b}"}, {"`a b`", "$(){a b}"}, {"\"`a`\"", `"$()"{a}`},
		{"$(a $(b))", "$(){a $(b)}"}, {`$(a "b)" c)`, `$(){a "b)" c}`}, {`$(a 'b)' c)`, `$(){a 'b)' c}`},
		{`$(a \) b)`, `$(){a \) b}`}, {"$(a (b) c)", "$(){a (b) c}"}, {"$(a (b c)", "!$(a (b c)"},
		{`$(a "b $(c)" d)`, `$(){a "b $(c)" d}`}, {`$(a "b\" c" d)`, `$(){a "b\" c" d}`}, {`$(a "$b)" c)`, `$(){a "$b)" c}`},
		{`$(a "$(b" )`, `!$(a "$(b" )`}, {`$(a "b)`, `!$(a "b)`}, {`$(a 'b)`, `!$(a 'b)`}, {"$(a", "!$(a"},
		{"x $(a", "x !$(a"}, {`x y="$(a`, `x !$(a`}, {`"$(a"`, `!$(a"`}, {"`a", "!`a"}, {"x `a", "x !`a"},
		{"`a\\`b`", "$(){a\\`b}"}, {`"$` + "(a" + `)"x"` + "`b`", `"$()"x"$(){a|b}`},
	}
	for _, c := range cases {
		if got := render(lex(c.in)); got != c.want {
			t.Errorf("lex(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLogicalLines(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", []string{""}}, {"a", []string{"a"}}, {"a\nb", []string{"a", "b"}}, {"a\\\nb", []string{"a b"}},
		{"a\\", []string{"a "}}, {"a\\\n", []string{"a "}}, {"a\\\n\\\nb", []string{"a  b"}}, {"a\\\nb\nc", []string{"a b", "c"}},
	}
	for _, c := range cases {
		if got := logicalLines(c.in); strings.Join(got, "|") != strings.Join(c.want, "|") || len(got) != len(c.want) {
			t.Errorf("logicalLines(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSourceLinesHereDocs(t *testing.T) {
	cases := []struct{ in, want string }{
		{"cat <<EOF\na\nEOF\nb", "cat <<EOF a b"},
		{"bash <<EOF\na\nEOF\nb", "bash <<EOF a* b"},
		{"cat <<EOF\na\n", "cat <<EOF a "},
		{"cat <<< x\nb", "cat <<< x b"},
		{"cat <<<EOF\nz", "cat <<<EOF z"},
		{"<<EOF\nx\nEOF\ny", "<<EOF x y"},
		{"sh <<-'EOF'\n\tx\n\tEOF\ny", "sh <<-'EOF' \tx* y"},
		{"sh <<\"EOF\"\nx\n  EOF  \ny", `sh <<"EOF" x* y`},
		{"sh <<\\EOF\nx\nEOF\ny", `sh <<\EOF x* y`},
		{"cat <<A <<B\n1\nA\n2", "cat <<A <<B 1 2"},
		{"cat <<EOF\nEOF\nb", "cat <<EOF b"},
		{"echo hi\nb", "echo hi b"},
	}
	for _, c := range cases {
		var p []string
		for _, l := range sourceLines(c.in) {
			p = append(p, l.Text+map[bool]string{true: "*", false: ""}[l.Exec])
		}
		if got := strings.Join(p, " "); got != c.want {
			t.Errorf("sourceLines(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
