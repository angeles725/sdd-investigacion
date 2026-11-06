package goimpact_test

import (
	"fmt"
	"strings"
	"testing"
)

// A command substitution is a new command context, quoted or bracketed or not: command position inside it is
// always class C, never the outer assignment (A) or bracket (B) state. calls is the SHIM edge, blind the BLIND class.
func TestCommandSubstitutionsAreNewCommandContexts(t *testing.T) {
	const call = `out="$("$RSDD_BIN" g one)"`
	cases := []struct{ name, src, shape, blind, calls string }{
		{"quoted assignment", call, "C+", "", "g one"},
		{"quoted non-literal", `out="$("$RSDD_BIN" "$x" one)"`, "C-", "C", ""},
		{"quoted in [ ]", `[ "$("$RSDD_BIN" g one)" = x ]`, "C+", "", "g one"},
		{"unquoted in [[ ]]", `[[ $("$RSDD_BIN" g one) == x ]]`, "C+", "", "g one"},
		{"quoted rsdd_exec", `x="$(rsdd_exec g one)"`, "C+", "", "g one"},
		{"nested", `x="$(echo "$("$RSDD_BIN" g one)")"`, "C+", "", "g one"},
		{"single-quoted paren inside", `out="$("$RSDD_BIN" g one 'a)b')"`, "C+", "", "g one"},
		{"unclosed", `x="$("$RSDD_BIN" g one`, "unplaceable", "unplaceable", ""},
		{"plain assignment stays A", `x="$RSDD_BIN"`, "A", "empty-reach", ""},
		{"plain bracket stays B", `[ -x "$RSDD_BIN" ]`, "B", "empty-reach", ""},
		{"first line", call + "\nexport RSDD_BIN\n", "C+ A", "", "g one"},
		{"middle line", "export RSDD_BIN\n" + call + "\nexport RSDD_BIN\n", "A C+ A", "", "g one"},
		{"last line", "export RSDD_BIN\n" + call + "\n", "A C+", "", "g one"},
	}
	files := map[string]string{}
	for i, c := range cases {
		files[fmt.Sprintf("%s%02d.sh", tb, i)] = c.src
	}
	got := scan(t, files)
	for i, c := range cases {
		f := got[fmt.Sprintf("%02d.sh", i)]
		var calls []string
		for _, k := range f.Calls {
			calls = append(calls, k.Cmd.String())
		}
		if shape(f) != c.shape || f.Blind() != c.blind || strings.Join(calls, ",") != c.calls {
			t.Errorf("%s: shape %q blind %q calls %q; want %q %q %q", c.name, shape(f), f.Blind(), strings.Join(calls, ","), c.shape, c.blind, c.calls)
		}
	}
}
