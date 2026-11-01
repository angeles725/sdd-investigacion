//go:build !nodiff

package gate

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential test: the FROZEN bash original (testdata/legacy/hook-pretool-pkill-guard.sh, a verbatim copy of
// templates/hook-pretool-pkill-guard.sh at the port commit) and the Go command must agree byte for byte on
// stdout, stderr and the exit code, in default and strict mode. testkit/parity is not used because its legacy
// root is origin/main, which moves on as the template is edited.
//
// bash runs under LC_ALL=C.utf8 (the locale the hook runs in; the bracket regex and sed work on characters).
// Only a missing bash or jq skips, with a message saying the Go port is NOT proven in that run.

const corpusRel = "../../../toolbelt/tests/fixtures/kit-writer-check/name-kill-corpus.txt"

type legacyOut struct {
	out, err string
	rc       int
}

func legacy(t *testing.T, stdin string, args ...string) legacyOut {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found; the Go guard is NOT proven against the bash original in this run")
	}
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("differential: jq not found; the Go guard is NOT proven against the bash original in this run")
	}
	script, err := filepath.Abs(filepath.Join("testdata", "legacy", "hook-pretool-pkill-guard.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("frozen legacy script missing: %v", err)
	}
	cmd := exec.Command(bash, append([]string{script}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C.utf8"}
	cmd.Stdin = strings.NewReader(stdin)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	rc := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("cannot run the legacy guard: %v", err)
		}
		rc = ee.ExitCode()
	}
	return legacyOut{so.String(), se.String(), rc}
}

func sameAsLegacy(t *testing.T, label, stdin string, args ...string) {
	t.Helper()
	want := legacy(t, stdin, args...)
	got := runGuard(stdin, args...)
	if got.out != want.out || got.err != want.err || got.rc != want.rc {
		t.Errorf("%s (args %v) diverges from the bash original\n stdin: %q\n  got: rc=%d out=%q err=%q\n want: rc=%d out=%q err=%q",
			label, args, stdin, got.rc, got.out, got.err, want.rc, want.out, want.err)
	}
}

func corpus(t *testing.T) (verdicts, cmds []string) {
	t.Helper()
	data, err := os.ReadFile(corpusRel)
	if err != nil {
		t.Fatalf("name-kill corpus not found (a moved fixture must update corpusRel, never skip): %v", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		v, c, ok := strings.Cut(line, "\t")
		if ok && (v == "deny" || v == "allow") {
			verdicts, cmds = append(verdicts, v), append(cmds, c)
		}
	}
	if len(cmds) < 20 {
		t.Fatalf("corpus read %d lines (silent zero?)", len(cmds))
	}
	return verdicts, cmds
}

func TestDifferentialCorpus(t *testing.T) {
	verdicts, cmds := corpus(t)
	for i, c := range cmds {
		for _, args := range [][]string{nil, {strictFlag}} {
			sameAsLegacy(t, "corpus "+verdicts[i], payload("Bash", c), args...)
		}
		// the shared verdict list itself: strict mode must match the recorded deny/allow
		dec, _ := decision(t, runGuard(payload("Bash", c), strictFlag).out)
		if (verdicts[i] == "deny") != (dec == "deny") {
			t.Errorf("corpus %s %q: strict decision %q", verdicts[i], c, dec)
		}
	}
}

func TestDifferentialSuiteCommands(t *testing.T) {
	for _, c := range append(append([]string{}, denyCmds...), allowCmds...) {
		for _, args := range [][]string{nil, {strictFlag}} {
			sameAsLegacy(t, "suite", payload("Bash", c), args...)
		}
	}
	sameAsLegacy(t, "non-Bash tool", payload("Write", "pkill -f foo"))
	sameAsLegacy(t, "unknown flag", payload("Bash", "ls"), "--no-such-flag")
	sameAsLegacy(t, "strict flag later in argv", payload("Bash", "killall x"), "a", "b", strictFlag)
}

// Shapes the suites do not name: separators, wrappers, brackets, quoting, unicode, encoder edges.
func TestDifferentialEdgeCommands(t *testing.T) {
	cmds := []string{
		"pkill -f", "pkill -f ''", "pkill -f \"\"", "pkill -f [", "pkill -f []", "pkill -f [abc]", "pkill -f [ab]oo [c]d",
		"pkill -f [f]oo [f]oo", "pkill -f f[o]o foo", "pkill -f [é]x é", "pkill -f [é]x", "pkill -f '[f]oo'; echo foo",
		"pkill --full --exact foo", "pkill --exact -f foo", "pkill -f -x foo", "pkill -e -f foo", "pkill -- -f foo",
		"pkill - foo", "pkill -F pidfile foo", "pkill --signal -f foo", "pgrep -a -f foo bar baz",
		"/usr/bin/killall x", "./pkill -f foo", "foo/ -f", "a/pkill -f foo", "pkill/ -f foo",
		"env FOO=1 pkill -f foo", "FOO=1 BAR=2 pkill -f foo", "timeout 5 pkill -f foo", "exec pkill -f foo", "nohup pkill -f foo",
		"xargs pkill -f foo", "time pkill -f foo", "9 pkill -f foo", "then pkill -f foo", "do pkill -f foo", "else pkill -f foo",
		"! pkill -f foo", "sudo -u root pkill -f foo", "sh -c pkill -f foo", "zsh pkill -f foo", "dash pkill -f foo",
		"echo a;pkill -f foo", "echo a&&pkill -f foo", "echo a||pkill -f foo", "(pkill -f foo)", "{ pkill -f foo; }", "echo $(pkill -f foo)",
		"x=`pkill -f foo`", "pkill -f foo &", "pkill\t-f\tfoo", "pkill  -f   foo", "pkill -f foo\r", "pkill -f foo\v", "\tpkill -f foo",
		"echo a\n\npkill -f foo\n", "echo a\n", "\n", "   ", ";;;", "pkill -f foo\npkill -f [f]oo", "pkill -f [f]oo\npgrep -f bar",
		"pgrep -f foo; kill -1", "pkill -x foo; kill -1", "kill -1; pkill -f foo", "kill -s TERM -1 -1", "kill -1x", "kill -01", "kill - 1",
		"kill -9 1", "kill 1", "kill -- -1", "kill  -1  ", "/bin/kill -1", "kill/ -1", "sudo kill -1", "echo kill -1", "killall", "killall -f x",
		"pkill", "pgrep", "pgrep foo | xargs kill", "pgrep foo | xargs -n1 kill -9", "pidof x | xargs kill", "pidof x | xargs killall",
		"pgrep x | xargs  kill", "pgrep x | xargs echo kill", "pgrep x | xargs skill", "pgrep x | xargs my-kill", "pgrep x | xargs kill_it",
		"pgrep x | xargs kill-it", "pgrep x | while read p; do kill $p; done", "pgrep x | tee f | xargs kill", "pgrep x && echo | xargs kill",
		"pgrep x | xargs ; kill", "kill $(pgrep x)", "kill $( pgrep x)", "kill `pgrep x`", "kill $(echo; pgrep x)", "kill $(pidof x)",
		"kill \"$(pgrep -x x)\"", "kill -9 $(pgrep x) $(pgrep y)", "xkill $(pgrep x)", "kill-all $(pgrep x)", "skill $(pgrep x)",
		"pkill -f 'a<b>&\x7f \x01\t'", "pkill -f \"é ü\"", "killall 'a<b>&\x7f \x01\t'", "pkill -f \\foo", "pkill -f \"a\\\\b\"",
		"pkill -f foo # comment", "echo 'pkill -f foo'", "echo \"pkill -f foo\"", "echo \"a; pkill -f foo\"", "echo 'a && pkill -x foo'",
	}
	for _, c := range cmds {
		for _, args := range [][]string{nil, {strictFlag}} {
			sameAsLegacy(t, "edge", payload("Bash", c), args...)
		}
	}
}

// Raw stdin shapes: parse failures, degraded branch, jq value semantics.
func TestDifferentialRawStdin(t *testing.T) {
	bashCmd := func(cmd string) string { return `{"tool_name":"Bash","tool_input":{"command":` + mustJSON(cmd) + `}}` }
	raw := map[string]string{
		"empty":                 "",
		"newline":               "\n",
		"spaces":                "   ",
		"spaces+newline":        " \n ",
		"garbage":               "{not json",
		"garbage+pkill":         "{not json pkill -f foo",
		"garbage+pgrep":         "pgrep",
		"truncated":             `{"tool_name":"Bash","tool_input":{"command":"pkill -f x"`,
		"truncated no pkill":    `{"tool_name":"Bash","tool_input":{"command":"ls"`,
		"array":                 `[1]`,
		"array+pkill":           `["pkill"]`,
		"string":                `"pkill -f x"`,
		"number":                `5`,
		"true":                  `true`,
		"null":                  `null`,
		"empty object":          `{}`,
		"no tool_input":         `{"tool_name":"Bash"}`,
		"null tool_input":       `{"tool_name":"Bash","tool_input":null}`,
		"string tool_input":     `{"tool_name":"Bash","tool_input":"pkill -f x"}`,
		"array tool_input":      `{"tool_name":"Bash","tool_input":[1]}`,
		"number tool_input":     `{"tool_name":"Bash","tool_input":3}`,
		"no command":            `{"tool_name":"Bash","tool_input":{}}`,
		"null command":          `{"tool_name":"Bash","tool_input":{"command":null}}`,
		"false command":         `{"tool_name":"Bash","tool_input":{"command":false}}`,
		"true command":          `{"tool_name":"Bash","tool_input":{"command":true}}`,
		"number command":        `{"tool_name":"Bash","tool_input":{"command":5}}`,
		"empty command":         `{"tool_name":"Bash","tool_input":{"command":""}}`,
		"tool_name number":      `{"tool_name":5,"tool_input":{"command":"pkill -f x"}}`,
		"tool_name null":        `{"tool_name":null,"tool_input":{"command":"pkill -f x"}}`,
		"tool_name missing":     `{"tool_input":{"command":"pkill -f x"}}`,
		"tool_name lowercase":   `{"tool_name":"bash","tool_input":{"command":"pkill -f x"}}`,
		"tool_name Write":       `{"tool_name":"Write","tool_input":{"command":"pkill -f x"}}`,
		"duplicate key":         `{"tool_name":"Bash","tool_input":{"command":"ls","command":"pkill -f x"}}`,
		"two values":            `{"tool_name":"Bash","tool_input":{"command":"ls"}} {"tool_name":"Bash","tool_input":{"command":"pkill -f x"}}`,
		"two values bad second": `{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}} {bad`,
		"two values 2nd allow":  `{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}} {"tool_name":"Write"}`,
		"nul in command":        `{"tool_name":"Bash","tool_input":{"command":"pkill\u0000 -f x"}}`,
		"nul only":              `{"tool_name":"Bash","tool_input":{"command":"\u0000"}}`,
		"trailing newlines":     bashCmd("pkill -f x\n\n\n"),
		"trailing newline JSON": bashCmd("pkill -f x") + "\n\n",
		"leading newline cmd":   bashCmd("\n\npkill -f x"),
		"unicode escapes":       `{"tool_name":"Bash","tool_input":{"command":"pkill -f é😀 \ud800"}}`,
		"invalid utf8 raw":      "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pkill -f \xff\xfe x\"}}",
		"bom":                   "\xef\xbb\xbf" + bashCmd("pkill -f x"),
		"extra fields":          `{"a":[1,2,{"b":null}],"tool_name":"Bash","tool_input":{"command":"pkill -f x","description":"d"},"z":1.5e3}`,
		"nested tool_input":     `{"tool_name":"Bash","tool_input":{"command":{"command":"pkill -f x"}}}`,
	}
	for name, in := range raw {
		if strings.HasPrefix(name, "nul ") {
			continue // bash prints a script-and-line specific "ignored null byte" warning; see TestDifferentialNulByte
		}
		for _, args := range [][]string{nil, {strictFlag}} {
			sameAsLegacy(t, "raw "+name, in, args...)
		}
	}
}

// Surrogate escapes (built from hex, never written literally): jq rejects a lone high surrogate, accepts the rest.
func TestDifferentialSurrogates(t *testing.T) {
	e := func(h ...string) string { return `\u` + strings.Join(h, `\u`) }
	for _, c := range []string{
		e("d800"), e("d800", "0041"), e("d800") + "z", e("dc00"), e("d83d", "de00"), e("d800", "dfff"), e("dbff", "dc00"), e("dbff"),
		e("d800", "dbff"), e("d800", "e000"), e("d7ff"), e("e000"), e("dfff"), e("d83d", "de00", "d800"), `\\` + e("d800"), `\\ud800`,
	} {
		in := `{"tool_name":"Bash","tool_input":{"command":"pkill -f x ` + c + `"}}`
		for _, args := range [][]string{nil, {strictFlag}} {
			sameAsLegacy(t, "surrogate "+c, in, args...)
		}
		sameAsLegacy(t, "surrogate in another key "+c, `{"a":"`+c+`","tool_name":"Bash","tool_input":{"command":"pkill -f x"}}`)
	}
}

// bash drops a NUL byte from a command substitution and warns on stderr with its own script path and line number;
// the Go port drops it silently (intended divergence): stdout and the exit code must still match.
func TestDifferentialNulByte(t *testing.T) {
	for _, in := range []string{
		`{"tool_name":"Bash","tool_input":{"command":"pkill\u0000 -f x"}}`,
		`{"tool_name":"Bash","tool_input":{"command":"\u0000"}}`,
	} {
		for _, args := range [][]string{nil, {strictFlag}} {
			want, got := legacy(t, in, args...), runGuard(in, args...)
			if got.out != want.out || got.rc != want.rc {
				t.Errorf("NUL payload %q (args %v): got rc=%d out=%q, want rc=%d out=%q", in, args, got.rc, got.out, want.rc, want.out)
			}
			if !strings.Contains(want.err, "ignored null byte") {
				t.Errorf("the bash original no longer warns about the NUL byte (%q); revisit this divergence", want.err)
			}
		}
	}
}

func mustJSON(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}
