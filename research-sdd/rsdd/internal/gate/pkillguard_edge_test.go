package gate

import (
	"os"
	"strings"
	"testing"
)

// Hand-written edge expectations (no bash oracle, so they also run under the nodiff tag of the mutation run).

// Each wrapper/keyword the guard skips before the command word, one at a time, plus the edges of the flag parser.
func TestEdgeVerdicts(t *testing.T) {
	type v struct {
		cmd           string
		deflt, strict bool // true = deny
	}
	var cases []v
	for _, w := range []string{"sudo", "exec", "env", "nohup", "xargs", "time", "timeout", "bash", "sh", "zsh", "dash", "then", "do", "else", "!", "if", "elif", "while", "until", "command", "nice", "FOO=1", "5", "-n"} {
		cases = append(cases, v{w + " pkill -f foo", true, true}, v{w + " killall x", false, true}, v{w + " kill -1", false, true})
	}
	cases = append(cases,
		v{"pkill -f", true, true}, v{"pkill -f [f]oo", false, true}, v{"pkill -f [f]oo foo", false, true}, v{"pkill -f [f]oo; echo foo", true, true},
		v{"pkill -f []", true, true}, v{"pkill -e -f foo", true, true}, v{"pkill --exact -f foo", false, true}, v{"pkill --full --exact foo", false, true},
		v{"pkill --signal -f foo", true, true}, v{"pkill --pidfile x", false, true}, v{"pkill -f --max foo", true, true}, v{"pkill - foo", false, true}, v{"pgrep -a -f foo", true, true},
		v{"a/pkill -f foo", true, true}, v{"pkill/ -f foo", false, false}, v{"echo a;pkill -f foo", true, true}, v{"(pkill -f foo)", true, true},
		v{"{ pkill -f foo; }", true, true}, v{"echo $(pkill -f foo)", true, true}, v{"pkill\t-f\tfoo", true, true},
		v{"pgrep -f foo; kill -1", true, true}, v{"kill -s TERM -1", false, true}, v{"kill -1x", false, false}, v{"kill - 1", false, false},
		v{"kill -9 1", false, false}, v{"/bin/kill -1", false, true}, v{"echo kill -1", false, false}, v{"killall", false, true}, v{"pkill", false, true},
		v{"pgrep foo | xargs kill", false, true}, v{"pgrep foo | xargs -n1 kill -9", false, true}, v{"pidof x | xargs killall", false, true},
		v{"pgrep x | xargs echo kill", false, true}, v{"pgrep x | xargs skill", false, false}, v{"pgrep x | xargs my-kill", false, false},
		v{"pgrep x | xargs kill_it", false, false}, v{"pgrep x | xargs kill-it", false, false}, v{"pgrep x | while read p; do kill $p; done", false, true},
		v{"pgrep x | xargs ; kill", false, true}, v{"kill $(pgrep x)", false, true}, v{"kill $( pgrep x)", false, true}, v{"kill `pgrep x`", false, true},
		v{"xkill $(pgrep x)", false, false}, v{"kill-all $(pgrep x)", false, true}, v{"skill $(pgrep x)", false, false}, v{"kill $(pidof x)", false, true},
		v{"echo a\n\npkill -f foo\n", true, true}, v{"   ", false, false}, v{";;;", false, false},
	)
	for _, c := range cases {
		for i, args := range [][]string{nil, {strictFlag}} {
			want := []bool{c.deflt, c.strict}[i]
			dec, _ := decision(t, runGuard(payload("Bash", c.cmd), args...).out)
			if (dec == "deny") != want {
				t.Errorf("%q (args %v): decision %q, want deny=%v", c.cmd, args, dec, want)
			}
		}
	}
}

// Reasons carry the offending text: the strict one the whole segment, the default one the pattern and, for a
// bracket pattern, the plain text that also appears elsewhere.
func TestReasonDetails(t *testing.T) {
	cases := []struct{ cmd, arg, frag string }{
		{"pkill -f", "", "Refused `pkill -f`:"},
		{"sudo pgrep -f a b", "", "Refused `pgrep -f a b`:"},
		{"cd /srv/foo && pkill -f '[f]oo'", "", "Refused `pkill -f [f]oo (its plain text \"foo\" also appears elsewhere in this command)`:"},
		{"pkill -f [a]b; echo ab", "", "Refused `pkill -f [a]b (its plain text \"ab\" also appears elsewhere in this command)`:"},
		{"echo x; /usr/bin/killall -9 python", strictFlag, "Refused name-based kill `/usr/bin/killall -9 python`:"},
		{"pgrep x | xargs kill", strictFlag, "Refused name-based kill `pgrep/pidof output piped into kill`:"},
		{"kill $(pidof x)", strictFlag, "Refused name-based kill `kill of a pgrep/pidof substitution`:"},
		{"pgrep -f foo; kill -1", "", "Refused `pgrep -f foo`:"}, // the refusal breaks the scan before the later kill -1 is seen
		{"pgrep -f foo; kill -1", strictFlag, "Refused `pgrep -f foo`:"},
	}
	for _, c := range cases {
		var args []string
		if c.arg != "" {
			args = []string{c.arg}
		}
		_, reason := decision(t, runGuard(payload("Bash", c.cmd), args...).out)
		if !strings.Contains(reason, c.frag) {
			t.Errorf("%q: reason %q lacks %q", c.cmd, reason, c.frag)
		}
	}
}

// jq value semantics for the extracted command.
func TestPayloadShapes(t *testing.T) {
	deny := map[string]string{
		"bom":          "\ufeff" + payload("Bash", "pkill -f x"),
		"two values":   `{"tool_name":"Write"} ` + payload("Bash", "pkill -f x"),
		"dup key":      `{"tool_name":"Bash","tool_input":{"command":"ls","command":"pkill -f x"}}`,
		"trailing nls": payload("Bash", "pkill -f x\n\n"),
		"nul dropped":  `{"tool_name":"Bash","tool_input":{"command":"pkill\u0000 -f x"}}`,
	}
	for n, in := range deny {
		if dec, _ := decision(t, runGuard(in).out); dec != "deny" {
			t.Errorf("%s: decision %q, want deny", n, dec)
		}
	}
	allow := map[string]string{
		"lowercase tool": `{"tool_name":"bash","tool_input":{"command":"pkill -f x"}}`, "number tool": `{"tool_name":5,"tool_input":{"command":"pkill -f x"}}`,
		"no tool": `{"tool_input":{"command":"pkill -f x"}}`, "null": `null`, "null input": `{"tool_name":"Bash","tool_input":null}`,
		"false cmd": `{"tool_name":"Bash","tool_input":{"command":false}}`, "number cmd": `{"tool_name":"Bash","tool_input":{"command":5}}`,
	}
	for n, in := range allow {
		if r := runGuard(in); r != (result{}) {
			t.Errorf("%s: %+v, want silent allow", n, r)
		}
	}
	for _, in := range []string{`[1]`, `"x"`, `5`, `{"tool_name":"Bash","tool_input":"s"}`, `{"tool_name":"Bash","tool_input":[1]}`, `{"tool_name":"Bash"} {bad`} {
		if r := runGuard(in); r.rc != 0 || r.out != "" || !strings.HasPrefix(r.err, "degraded: pkill-guard: stdin is not parseable") {
			t.Errorf("%q must degrade on stderr: %+v", in, r)
		}
	}
	if r := runGuard(`pgrep`); !strings.Contains(r.out, `"ask"`) {
		t.Errorf("unparseable payload mentioning pgrep must ask: %+v", r)
	}
}

// jq 1.7+ rejects a lone high surrogate escape as a parse error (degraded), accepts a pair and a lone low surrogate,
// and an escaped backslash before "ud800" is not an escape. encoding/json would accept all of them.
func TestSurrogateEscapes(t *testing.T) {
	wrap := func(c string) string { return `{"tool_name":"Bash","tool_input":{"command":"` + c + `"}}` }
	// e builds JSON \uXXXX escapes from hex digits; the escapes are never written literally in this source.
	e := func(h ...string) string { return `\u` + strings.Join(h, `\u`) }
	for _, c := range []string{
		"pkill -f x " + e("d800"), "pkill -f x " + e("d800", "0041"), "pkill -f x " + e("d800") + "z", e("d800") + " pkill -f x",
		`a\\` + e("d800"), "x " + e("dbff") + "z", "x " + e("d83d", "de00", "d800"), e("dbff", "d800", "dc00") + " pkill -f x",
		"pkill -f x " + e("d800", "dbff"), "pkill -f x " + e("d800", "e000"), "pkill -f x " + e("d800") + e("dc00")[:5],
	} {
		if r := runGuard(wrap(c)); !strings.HasPrefix(r.err, "degraded: pkill-guard: stdin is not parseable") {
			t.Errorf("%q: want the typed degraded line, got %+v", c, r)
		}
	}
	for _, c := range []string{
		"pkill -f x " + e("d83d", "de00"), "pkill -f x " + e("dc00"), `pkill -f x \\ud800`, "pkill -f x " + e("d800", "dfff"),
		"pkill -f x " + e("00e9", "d800", "dc00"), "pkill -f x " + e("dbff", "dc00"), "pkill -f x " + e("d800", "dc00"),
		"pkill -f x " + e("d83d", "de00") + e("d83d", "de00"), "pkill -f x " + e("d800", "dc00") + " " + e("0041"),
		"pkill -f x " + e("dfff"), "pkill -f x " + e("d7ff"), "pkill -f x " + e("e000"),
	} {
		if dec, _ := decision(t, runGuard(wrap(c)).out); dec != "deny" {
			t.Errorf("%q: valid escapes must be judged, decision %q", c, dec)
		}
	}
	if r := runGuard(`{"a":"` + e("d800") + `"} {"tool_name":"Bash"}`); !strings.HasPrefix(r.err, "degraded: pkill-guard:") {
		t.Errorf("a lone surrogate in any value must degrade: %+v", r)
	}
	// a lone surrogate outside any string is not an escape; the document is simply invalid either way
	if r := runGuard(wrap("pkill -f x") + e("d800")); !strings.HasPrefix(r.err, "degraded: pkill-guard:") {
		t.Errorf("trailing junk must degrade: %+v", r)
	}
}

// The shared verdict list (also pinned by the writer-check scan) read in strict mode.
func TestStrictCorpus(t *testing.T) {
	data, err := os.ReadFile("../../../toolbelt/tests/fixtures/kit-writer-check/name-kill-corpus.txt")
	if err != nil {
		t.Fatalf("corpus not found: %v", err)
	}
	n := 0
	for _, line := range strings.Split(string(data), "\n") {
		verdict, c, ok := strings.Cut(line, "\t")
		if !ok || (verdict != "deny" && verdict != "allow") {
			continue
		}
		n++
		dec, _ := decision(t, runGuard(payload("Bash", c), strictFlag).out)
		if (verdict == "deny") != (dec == "deny") {
			t.Errorf("corpus %s %q: strict decision %q", verdict, c, dec)
		}
	}
	if n < 20 {
		t.Fatalf("corpus read %d lines (silent zero?)", n)
	}
}
