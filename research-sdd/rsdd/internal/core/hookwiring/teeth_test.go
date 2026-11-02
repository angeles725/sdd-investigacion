package hookwiring

import (
	"strings"
	"testing"
)

// Boundary pins for the character classes of isNameVal: every edge of every range, in the first position and after it.
func TestIsNameValCharacterRanges(t *testing.T) {
	for _, tt := range []struct {
		in             string
		matches, valid bool
	}{
		{"_=1", true, true}, {"a=1", true, true}, {"z=1", true, true}, {"A=1", true, true}, {"Z=1", true, true},
		{"Xa=1", true, true}, {"Xz=1", true, true}, {"XZ=1", true, true}, {"X0=1", true, true}, {"X9=1", true, true},
		{"X_=1", true, true}, {"XA=1", true, true},
		{"X-=1", true, false}, {"X`=1", true, false}, {"X{=1", true, false}, {"X[=1", true, false},
		{"X/=1", true, false}, {"X:=1", true, false}, {"X@=1", true, false},
		{"`=1", false, false}, {"{=1", false, false}, {"[=1", false, false}, {"@=1", false, false},
		{"0=1", false, false}, {"abc", false, false}, {"", false, false},
	} {
		if m, v := isNameVal(tt.in); m != tt.matches || v != tt.valid {
			t.Errorf("isNameVal(%q) = (%v, %v), want (%v, %v)", tt.in, m, v, tt.matches, tt.valid)
		}
	}
}

// A lone high surrogate is only an error inside a string, and a pair has to be complete to the last byte.
// "@" stands for the backslash-u that starts a JSON unicode escape.
func TestLoneHighSurrogateEdges(t *testing.T) {
	for _, tt := range []struct {
		in   string
		want bool
	}{
		{`@d800`, false},             // outside a string nothing is scanned
		{`"@d800`, true},             // the data ends right after the escape
		{`"@d800@dc00`, false},       // a pair that ends exactly at the end of the data
		{`"@d800@dbff`, true},        // a second high surrogate is no pair
		{`"@d800@dfff`, false},       // the last low surrogate
		{`"@d800@e000`, true},        // the first code unit above the low range
		{`"@d800@0041`, true},        // not a surrogate at all
		{`"@d800@d`, true},           // truncated second escape
		{`"@d800x`, true},            // no second escape
		{`"@d800@dc00"@d800`, false}, // the string closed before the next escape
		{`"@dc00`, false},            // a lone low surrogate is accepted
	} {
		in := strings.ReplaceAll(tt.in, "@", `\u`)
		if got := loneHighSurrogate([]byte(in)); got != tt.want {
			t.Errorf("loneHighSurrogate(%q) = %v, want %v", in, got, tt.want)
		}
	}
}

// An empty event name is a real event key: the report quotes it as the empty detail, not the whole entry line.
func TestWiredExecEmptyEventName(t *testing.T) {
	r, _ := sandbox(t)
	target, home := execFixture(t, r)
	writeFile(t, target+"/.claude/settings.json",
		`{"hooks":{"":[{"hooks":[{"type":"command","command":"`+pdir+`/absent"}]}]}}`)
	e := envOf(r, map[string]string{envHome: home})
	if got, want := goExec(t, e, target), "missing\t"+target+"/.claude/hooks/absent\t"+nl; got != want {
		t.Errorf("report = %q, want %q", got, want)
	}
}
