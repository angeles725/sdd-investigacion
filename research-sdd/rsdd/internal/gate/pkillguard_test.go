package gate

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Verdict tests for the PreToolUse pkill guard (kit issues #1244, #2208). The expectations below are written by
// hand from the contract in templates/hook-pretool-pkill-guard.sh, not derived from the Go code under test; the
// differential test (pkillguard_diff_test.go) separately proves byte parity with the frozen bash original.

const strictFlag = "--strict-name-kill"

// payload builds the PreToolUse hook JSON for one tool call.
func payload(tool, cmd string) string {
	b, err := json.Marshal(map[string]any{
		"hook_event_name": "PreToolUse",
		"tool_name":       tool,
		"tool_input":      map[string]any{"command": cmd},
	})
	if err != nil {
		panic(err)
	}
	return string(b)
}

type result struct {
	out, err string
	rc       int
}

func runGuard(stdin string, args ...string) result {
	var o, e bytes.Buffer
	rc := PkillGuard(args, cli.Stdio{In: strings.NewReader(stdin), Out: &o, Err: &e, Env: func(string) string { return "" }})
	return result{o.String(), e.String(), rc}
}

func decision(t *testing.T, out string) (dec, reason string) {
	t.Helper()
	if out == "" {
		return "", ""
	}
	var v struct {
		H struct {
			Event  string `json:"hookEventName"`
			Dec    string `json:"permissionDecision"`
			Reason string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatalf("stdout is not hook JSON: %v\n%s", err, out)
	}
	if v.H.Event != "PreToolUse" {
		t.Fatalf("hookEventName = %q, want PreToolUse", v.H.Event)
	}
	return v.H.Dec, v.H.Reason
}

// The suite's own command lists (toolbelt/tests/hook-pretool-pkill-guard.test.sh sections 1 and 2).
var denyCmds = []string{
	`pkill -f foo`, `pgrep -f foo`, `pkill -fl foo`, `pkill -9 -f foo`, `pkill --full foo`, `pkill -f 'my server'`,
	`pkill -f "$PAT"`, `pkill -f foo; echo done`, `echo a && pkill -f foo && echo b`, `echo a; echo b; pkill -f foo`,
	`ps aux | pgrep -f foo`, `kill $(pgrep -f foo)`, "kill `pgrep -f foo`", `sudo pkill -f foo`, `bash -c 'pkill -f foo'`,
	"echo hi\npkill -f foo", `/usr/bin/pkill -f foo`, `pkill -f [f]oo; pgrep -f bar`,
	`if pgrep -f foo >/dev/null; then echo up; fi`, `if true; then :; elif pgrep -f foo; then :; fi`,
	`while pkill -f foo; do sleep 1; done`, `until pgrep -f foo; do sleep 1; done`, `command pkill -f foo`,
	`nice -n 5 pkill -f foo`, `if ! pgrep -f foo; then :; fi`, `cd /srv/foo && pkill -f '[f]oo'`,
	`./foo & sleep 1; pkill -f '[f]oo'`, `echo foo --serve; pkill -f '[f]oo --serve'`, `git commit -m "x; pkill -f foo"`,
}

var allowCmds = []string{
	`pkill -f [f]oo`, `pkill -f '[f]oo --serve'`, `pkill -9 -f "[s]erver"`, `pgrep -f [f]oo`,
	`if pgrep -f [f]oo; then echo up; fi`, `cd /srv/app && pkill -f [f]oo`, `pkill -x foo`, `pkill -fx foo`, `pkill foo`,
	`pgrep -l foo`, `kill "$(cat /tmp/foo.pid)"`, `git commit -m "docs: never run pkill -f foo"`, `grep -rn "pkill -f" docs/`,
	`echo use pkill -f carefully`, `ls -la`, ``,
}

func TestDefaultModeDeny(t *testing.T) {
	for _, c := range denyCmds {
		r := runGuard(payload("Bash", c))
		dec, reason := decision(t, r.out)
		if r.rc != 0 || dec != "deny" || r.err != "" {
			t.Errorf("%q: rc=%d dec=%q err=%q, want rc 0 deny", c, r.rc, dec, r.err)
		}
		if !strings.Contains(reason, "Safe alternatives:") {
			t.Errorf("%q: reason lacks the alternatives: %q", c, reason)
		}
	}
}

func TestDefaultModeAllow(t *testing.T) {
	for _, c := range allowCmds {
		if r := runGuard(payload("Bash", c)); r != (result{}) {
			t.Errorf("%q: got %+v, want a silent allow (rc 0, no output)", c, r)
		}
	}
	if r := runGuard(payload("Write", "pkill -f foo")); r != (result{}) {
		t.Errorf("non-Bash tool carrying pkill text: got %+v, want silent allow", r)
	}
}

// Exact bytes of the two refusals: these strings are the user-visible contract of the hook.
func TestExactReasons(t *testing.T) {
	const alt = "Safe alternatives: (a) record the PID at spawn ($! or a PID file) and kill that PID; (b) match by exact process name: pkill -x <name> / pgrep -x <name>; (c) bracket-escape the pattern so it cannot match its own text: pkill -f \"[p]attern\". See PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics \"PKILL -F WRAPPER-SHELL MATCH\"."
	r := runGuard(payload("Bash", "pkill -f foo"))
	want := `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Refused ` + "`pkill -f foo`" + `: an unescaped -f pattern also matches this shell's own wrapper command line and kills the session (exit 144). ` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(alt) + `"}}` + "\n"
	if r.out != want {
		t.Errorf("default deny bytes:\n got %q\nwant %q", r.out, want)
	}
	r = runGuard(payload("Bash", "bash -c 'x'; kill -9 -1"), strictFlag)
	const strictText = `Kill only processes you started yourself, by PID: record $! when you spawn the process (or read it back with jobs -p), kill that PID, and bound a runaway run with timeout. Never match processes by name or pattern: a name match can hit another session's processes.`
	want = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Refused name-based kill ` + "`kill -9 -1`" + `: this repo forbids killing processes by name or pattern (writer discipline, kit issue #2208). ` + strictText + `"}}` + "\n"
	if r.out != want {
		t.Errorf("strict deny bytes:\n got %q\nwant %q", r.out, want)
	}
}

// The default mode never inherits the strict verdicts; strict keeps every default one.
func TestStrictVersusDefault(t *testing.T) {
	strictOnly := []string{`pkill -x foo`, `pkill foo`, `killall python3`, `kill -9 -1`, `kill -- -1`, `pgrep -f [f]oo | xargs kill`, `kill $(pidof loop)`, `pidof loop | xargs -r kill`}
	for _, c := range strictOnly {
		if r := runGuard(payload("Bash", c)); r != (result{}) {
			t.Errorf("default mode %q: got %+v, want allow", c, r)
		}
		if dec, _ := decision(t, runGuard(payload("Bash", c), strictFlag).out); dec != "deny" {
			t.Errorf("strict mode %q: decision %q, want deny", c, dec)
		}
	}
	for _, c := range denyCmds {
		if dec, _ := decision(t, runGuard(payload("Bash", c), strictFlag).out); dec != "deny" {
			t.Errorf("strict mode lost the default refusal of %q", c)
		}
	}
	for _, c := range []string{`kill 1234`, `kill $!`, `kill -0 $$`, `jobs -p | xargs kill`, `pgrep -x loop`} {
		if r := runGuard(payload("Bash", c), strictFlag); r != (result{}) {
			t.Errorf("strict mode %q: got %+v, want allow", c, r)
		}
	}
	if r := runGuard(payload("Bash", "pkill foo"), "--no-such-flag"); r != (result{}) {
		t.Errorf("an unknown argument must be ignored, got %+v", r)
	}
}

// Degraded inputs: typed on stderr, never a silent allow of a payload that mentions pkill/pgrep.
func TestDegradedInput(t *testing.T) {
	r := runGuard(`{not json pkill -f foo`)
	dec, reason := decision(t, r.out)
	if r.rc != 0 || dec != "ask" || !strings.HasPrefix(r.err, "degraded: pkill-guard: stdin is not parseable PreToolUse JSON") {
		t.Errorf("malformed + pkill: %+v", r)
	}
	if !strings.Contains(reason, "pkill-guard degraded (stdin is not parseable PreToolUse JSON)") {
		t.Errorf("reason: %q", reason)
	}
	r = runGuard(`{not json`)
	if r.rc != 0 || r.out != "" || !strings.HasPrefix(r.err, "degraded: pkill-guard:") {
		t.Errorf("malformed without pkill must degrade on stderr and allow: %+v", r)
	}
	for _, in := range []string{"", "\n\n"} {
		if r := runGuard(in); r != (result{}) {
			t.Errorf("empty stdin %q: %+v, want silent allow", in, r)
		}
	}
}

type errReader struct{ data string }

func (e *errReader) Read(p []byte) (int, error) {
	if e.data == "" {
		return 0, errors.New("boom")
	}
	n := copy(p, e.data)
	e.data = e.data[n:]
	return n, nil
}

// Fail-closed: when stdin cannot be read the guard cannot have inspected the command. Strict mode DENIES,
// default mode asks; neither allows silently (an intended divergence from bash, which cannot see a read error).
func TestUnreadableStdinFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{{[]string{strictFlag}, "deny"}, {nil, "ask"}} {
		var o, e bytes.Buffer
		rc := PkillGuard(tc.args, cli.Stdio{In: &errReader{data: `{"tool_name":"Bash"`}, Out: &o, Err: &e})
		dec, _ := decision(t, o.String())
		if rc != 0 || dec != tc.want || !strings.HasPrefix(e.String(), "degraded: pkill-guard: stdin unreadable") {
			t.Errorf("args %v: rc=%d dec=%q err=%q, want %s", tc.args, rc, dec, e.String(), tc.want)
		}
	}
}

// jq's string encoding, not encoding/json's: no HTML escaping, lowercase \u00xx, DEL escaped, U+2028 raw.
func TestJQStringEncoding(t *testing.T) {
	cases := map[string]string{
		"a<b>&c":        "a<b>&c",
		"tab\tnl\ncr\r": `tab\tnl\ncr\r`,
		"\x01\x1f":      `\u0001\u001f`,
		"\x7f":          `\u007f`,
		" é":            " é",
		"q\"b\\":        `q\"b\\`,
		"\b\f":          `\b\f`,
		"bad\xffbyte":   "bad�byte",
	}
	for in, want := range cases {
		if got := jqString(in); got != `"`+want+`"` {
			t.Errorf("jqString(%q) = %s, want %q", in, got, `"`+want+`"`)
		}
	}
}
