package maint

import (
	"reflect"
	"strings"
	"testing"
)

func mustDecode(t *testing.T, s string) any {
	t.Helper()
	v, err := decodeJSON([]byte(s))
	if err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
	return v
}

func TestPyDumpsKeepsOrderAndPythonSeparators(t *testing.T) {
	cases := map[string]string{
		`{"b":1,"a":[1,2.5,true,null,"x"],"c":{}}`: `{"b": 1, "a": [1, 2.5, true, null, "x"], "c": {}}`,
		"{\"k\":\"\u00e9<>&\\n\"}":                 "{\"k\": \"\\u00e9<>&\\n\"}",
		`[]`:                                       `[]`,
		`{"a":1,"a":2,"b":3}`:                      `{"a": 2, "b": 3}`,
		`1e2`:                                      `100.0`,
	}
	for in, want := range cases {
		if got := pyDumps(mustDecode(t, in)); got != want {
			t.Errorf("%s: got %s, want %s", in, got, want)
		}
	}
}

func TestPyIndentedSorted(t *testing.T) {
	got := pyIndented(mustDecode(t, `{"b":[1],"a":{"z":null}}`))
	want := "{\n  \"a\": {\n    \"z\": null\n  },\n  \"b\": [\n    1\n  ]\n}"
	if got != want {
		t.Fatalf("got\n%s", got)
	}
}

func TestPyStrAndRepr(t *testing.T) {
	cases := []struct {
		in, str, repr string
	}{
		{`null`, "None", "None"},
		{`true`, "True", "True"},
		{`false`, "False", "False"},
		{`"risk"`, "risk", "'risk'"},
		{`"it's"`, "it's", `"it's"`},
		{`"a'b\"c"`, `a'b"c`, `'a\'b"c'`},
		{`"tab\tnl\n\\"`, "tab\tnl\n\\", `'tab\tnl\n\\'`},
		{`"\u0001\u00e9\u200b"`, "\x01\u00e9\u200b", "'\\x01\u00e9\\u200b'"},
		{`"\r"`, "\r", `'\r'`},
		{`"😀"`, "😀", "'😀'"},
		{`[1,"a",null]`, "[1, 'a', None]", "[1, 'a', None]"},
		{`{"k":[true]}`, "{'k': [True]}", "{'k': [True]}"},
		{`1.0`, "1.0", "1.0"},
		{`7`, "7", "7"},
	}
	for _, c := range cases {
		v := mustDecode(t, c.in)
		if got := pyStr(v); got != c.str {
			t.Errorf("str(%s) = %q, want %q", c.in, got, c.str)
		}
		if got := pyRepr(v); got != c.repr {
			t.Errorf("repr(%s) = %q, want %q", c.in, got, c.repr)
		}
	}
	if got := pyStrRepr(string(rune(0x10ffff))); got != `'\U0010ffff'` {
		t.Errorf("astral non-printable: %s", got)
	}
}

func TestTruthy(t *testing.T) {
	yes := []string{`true`, `"x"`, `1`, `-0.5`, `[0]`, `{"a":null}`}
	no := []string{`null`, `false`, `""`, `0`, `0.0`, `-0`, `0e5`, `[]`, `{}`}
	for _, s := range yes {
		if !truthy(mustDecode(t, s)) {
			t.Errorf("%s should be truthy", s)
		}
	}
	for _, s := range no {
		if truthy(mustDecode(t, s)) {
			t.Errorf("%s should be falsy", s)
		}
	}
}

func TestDecodeJSONRejects(t *testing.T) {
	for _, s := range []string{``, `{`, `{} {}`, `[1,]`, `abc`, `{"a":}`, `[1 2]`} {
		if _, err := decodeJSON([]byte(s)); err == nil {
			t.Errorf("%q must not decode", s)
		}
	}
	if v, err := decodeJSON([]byte(" \n{\"a\":1}\n ")); err != nil || v == nil {
		t.Errorf("surrounding whitespace: %v", err)
	}
}

func TestObjAccessors(t *testing.T) {
	o := mustDecode(t, `{"a":null,"b":1}`).(*obj)
	if !o.has("a") || o.get("a") != nil || o.has("z") || !reflect.DeepEqual(o.keys, []string{"a", "b"}) {
		t.Fatalf("%+v", o)
	}
}

func TestHeadTail(t *testing.T) {
	if head("abcdef", 3) != "abc" || head("abc", 3) != "abc" || head("ab", 3) != "ab" || head("éèà", 2) != "éè" {
		t.Error("head")
	}
	if tail("abcdef", 3) != "def" || tail("abc", 3) != "abc" || tail("ab", 3) != "ab" || tail("éèà", 2) != "èà" {
		t.Error("tail")
	}
}

func TestShlexSplit(t *testing.T) {
	ok := map[string][]string{
		``:                             nil,
		`   `:                          nil,
		`a b  c`:                       {"a", "b", "c"},
		`a "b c" d`:                    {"a", "b c", "d"},
		`a 'b "c"' d`:                  {"a", `b "c"`, "d"},
		`a\ b`:                         {"a b"},
		`"a\"b"`:                       {`a"b`},
		`"a\\b"`:                       {`a\b`},
		`"a\nb"`:                       {`a\nb`},
		`''`:                           {""},
		`a'b'"c"`:                      {"abc"},
		"a\tb\nc":                      {"a", "b", "c"},
		`sh -c 'touch PWNED'`:          {"sh", "-c", "touch PWNED"},
		`gentle-ai review start --x=1`: {"gentle-ai", "review", "start", "--x=1"},
		`x\"y`:                         {`x"y`},
		`'a\b'`:                        {`a\b`},
		`# not a comment`:              {"#", "not", "a", "comment"},
	}
	for in, want := range ok {
		got, err := shlexSplit(in)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%q: got %q err=%v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{`'a`, `"a`, `a\`, `"a\`} {
		if _, err := shlexSplit(in); err == nil {
			t.Errorf("%q must fail", in)
		}
	}
}

func TestParseArgs(t *testing.T) {
	specs := []optSpec{{name: "consent", choices: []string{"granted"}}, {name: "base-ref", def: "origin/main"}, {name: "n", integer: true, def: "40"}}
	good := []struct {
		args []string
		opts map[string]string
		pos  []string
	}{
		{[]string{"a", "b"}, map[string]string{"consent": "", "base-ref": "origin/main", "n": "40"}, []string{"a", "b"}},
		{[]string{"--consent", "granted", "a", "b"}, map[string]string{"consent": "granted", "base-ref": "origin/main", "n": "40"}, []string{"a", "b"}},
		{[]string{"a", "--base-ref=x", "b"}, map[string]string{"consent": "", "base-ref": "x", "n": "40"}, []string{"a", "b"}},
		{[]string{"--base", "x", "a", "b"}, map[string]string{"consent": "", "base-ref": "x", "n": "40"}, []string{"a", "b"}},
		{[]string{"--", "--a", "-b"}, map[string]string{"consent": "", "base-ref": "origin/main", "n": "40"}, []string{"--a", "-b"}},
		{[]string{"-", "-3"}, map[string]string{"consent": "", "base-ref": "origin/main", "n": "40"}, []string{"-", "-3"}},
		{[]string{"--n", "-7", "a", "b"}, map[string]string{"consent": "", "base-ref": "origin/main", "n": "-7"}, []string{"a", "b"}},
		{[]string{"--n", "-.5x", "a", "b"}, nil, nil},
		{[]string{"--base-ref", "1", "--base-ref", "2", "a", "b"}, map[string]string{"consent": "", "base-ref": "2", "n": "40"}, []string{"a", "b"}},
	}
	for _, c := range good {
		p, err := parseArgs(c.args, specs, "x", "y")
		if c.opts == nil {
			if err == nil {
				t.Errorf("%v must fail", c.args)
			}
			continue
		}
		if err != nil || !reflect.DeepEqual(p.opts, c.opts) || !reflect.DeepEqual(p.pos, c.pos) {
			t.Errorf("%v: got %+v err=%v", c.args, p, err)
		}
	}
	bad := [][]string{
		{"a"}, {"a", "b", "c"}, {"--consent", "no", "a", "b"}, {"--n", "x", "a", "b"}, {"--zzz", "a", "b"},
		{"--c"}, {"--consent"}, {"--base-ref", "--consent", "a", "b"}, {"-x", "a", "b"}, {"--=x", "a", "b"}, {"--n=", "a", "b"},
	}
	for _, args := range bad {
		if _, err := parseArgs(args, specs, "x", "y"); err == nil {
			t.Errorf("%v must fail", args)
		}
	}
	// ambiguity: both options begin with "ba"
	amb := []optSpec{{name: "base-ref"}, {name: "base-dir"}}
	if _, err := parseArgs([]string{"--ba", "x", "a", "b"}, amb, "x", "y"); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("ambiguous prefix: %v", err)
	}
	if p, err := parseArgs([]string{"-h"}, specs, "x", "y"); err != nil || !p.help {
		t.Errorf("-h: %+v %v", p, err)
	}
	if p, err := parseArgs([]string{"--he"}, specs, "x", "y"); err != nil || !p.help {
		t.Errorf("--he: %+v %v", p, err)
	}
}
