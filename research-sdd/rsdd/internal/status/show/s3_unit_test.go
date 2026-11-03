package show

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAwkVEscapes(t *testing.T) {
	for in, want := range map[string]string{
		`a\tb`: "a\tb", `a\\b`: `a\b`, `a\qb`: "aqb", `a\101b`: "aAb", `a\x41b`: "aAb", `a\x414`: "aA4", `a\x4`: "a\x04", `a\x`: "ax", `a\xg`: "axg",
		`a\18`: "a\x018", `a\8`: "a8", `a\1`: "a\x01", `a\0777`: "a?7", `a\/b`: "a/b", `a\"b`: `a"b`, "a\\\nb": "ab", `a\`: "a", `plain`: "plain",
		`\a\b\f\n\r\t\v`: "\a\b\f\n\r\t\v", `\xAf`: "\xaf", `\xaF`: "\xaf", `\xA`: "\x0a", `\xa`: "\x0a", `\xG`: "xG", `\7\07\007`: "\a\a\a", `\1234`: "S4",
	} {
		if got := awkVEscapes(in); got != want {
			t.Errorf("awkVEscapes(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHexVal(t *testing.T) {
	for i, c := range "0123456789abcdef" {
		if hexVal(byte(c)) != i || !isHex(byte(c)) {
			t.Errorf("hex %q", c)
		}
	}
	for i, c := range "ABCDEF" {
		if hexVal(byte(c)) != 10+i || !isHex(byte(c)) {
			t.Errorf("hex %q", c)
		}
	}
	for _, c := range "gG/:@`xz " {
		if isHex(byte(c)) {
			t.Errorf("%q is not hex", c)
		}
	}
}

func TestIsWordByte(t *testing.T) {
	for c := 0; c < 256; c++ {
		want := c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '-'
		if isWordByte(byte(c)) != want {
			t.Errorf("isWordByte(%#x) = %v", c, !want)
		}
	}
}

func TestIntOf(t *testing.T) {
	for in, want := range map[string]bool{"0": true, "007": true, "9223372036854775807": true, "9223372036854775808": false, "": false, "-1": false, "1x": false, " 1": false} {
		if _, ok := intOf(in); ok != want {
			t.Errorf("intOf(%q) ok = %v", in, ok)
		}
	}
	if n, _ := intOf("007"); n != 7 {
		t.Error("007")
	}
	if atoiOrZero("12") != 12 || atoiOrZero("") != 0 || atoiOrZero("x") != 0 {
		t.Error("atoiOrZero")
	}
	if orDefault("", "d") != "d" || orDefault("v", "d") != "v" {
		t.Error("orDefault")
	}
}

func TestGrepERE(t *testing.T) {
	for _, tc := range []struct {
		in, want string
		unclosed bool
	}{
		{"ab-", "ab-", false}, {"a(b)-", "a(b)-", false}, {"a)-", `a\)-`, false}, {"a(-", "a(-", true}, {`a\(-`, `a\(-`, false},
		{`a\)b)`, `a\)b\)`, false}, {"(a))", `(a)\)`, false}, {`a\`, `a\`, false}, {"((a)", "((a)", true}, {"", "", false},
	} {
		got, unclosed := grepERE(tc.in)
		if got != tc.want || unclosed != tc.unclosed {
			t.Errorf("grepERE(%q) = %q, %v; want %q, %v", tc.in, got, unclosed, tc.want, tc.unclosed)
		}
	}
}

func TestNegatedWindow(t *testing.T) {
	for pre, want := range map[string]bool{
		"": false, "x ": false, "NOT ": true, "not ": true, "Not": true, "NOT A ": true, "NOT A B ": false, "not A ": false, "NOT YET ": true, "not yet ": true,
		"not x ": false, "YET ": false, "NOT - ": true, "NOT -- ": true, "NOT __ ": true, "NOT ---- A ": true, "X-NO ": false, "NO ": true, "NEVER ": true,
		"never ": true, "KNOT ": false, "NOW ": false, "--": false, "NOT NOT X ": true, "not LONGER ": true, "x NOT ": true,
	} {
		if got := negated(pre); got != want {
			t.Errorf("negated(%q) = %v, want %v", pre, got, want)
		}
	}
}

func TestHasWordRescansAfterARejectedMatch(t *testing.T) {
	for s, want := range map[string]bool{
		"CLOSED": true, "XCLOSED": false, "CLOSEDX": false, "CLOSEDCLOSED": false, "CLOSEDCLOSED CLOSED": true, "NOT CLOSED CLOSED": false, "NOT CLOSED but CLOSED": true,
		"NOT CLOSED": false, "a CLOSED": true, "": false, "CLOSE": false, "-CLOSED": false, "CLOSED-": false, "(CLOSED)": true,
	} {
		if got := hasWord(s, "CLOSED"); got != want {
			t.Errorf("hasWord(%q) = %v, want %v", s, got, want)
		}
	}
}

func TestChildClosedStrike(t *testing.T) {
	for s, want := range map[string]bool{
		"- ~~x": true, "-\t~~x": true, "- **~~x": true, "-~~x": false, "- *~~x": false, "- x ~~y": false, "  - ~~x": true, "~~x": false, "- **x": false, "-": false,
		"- [closed]": true, "- [CERRADO]": true, "- [clos ed]": false, "- ✅": true,
	} {
		if got := childClosed(s); got != want {
			t.Errorf("childClosed(%q) = %v, want %v", s, got, want)
		}
	}
}

func TestBulletShapes(t *testing.T) {
	for s, want := range map[string]bool{"- a": true, "-\ta": true, "  - a": true, "-a": false, "-": false, "a - b": false, "": false} {
		if isBulletLine(s) != want {
			t.Errorf("isBulletLine(%q) = %v", s, !want)
		}
	}
	for s, want := range map[string]bool{"- needs:": true, "- a NEEDS: x": true, "-needs: x": false, "needs: x": false, "- need: x": false, "-": false, "- a needs x": false} {
		if isNeedsBullet(s) != want {
			t.Errorf("isNeedsBullet(%q) = %v", s, !want)
		}
	}
}

func TestOnlyHas(t *testing.T) {
	c := &ctx{}
	if !c.onlyHas("known_gaps") {
		t.Error("no --only names everything")
	}
	c.opts = options{onlySet: true, onlyList: "blocked_open,known_gaps"}
	for name, want := range map[string]bool{"known_gaps": true, "blocked_open": true, "gaps_closed": false, "known": false, "open": false} {
		if c.onlyHas(name) != want {
			t.Errorf("onlyHas(%q) = %v", name, !want)
		}
	}
}

// A directory that cannot take the temp file is a typed refusal: nothing is written and nothing is left behind.
func TestSyncStateUnwritableDirectoryRefusesWithoutTouchingTheFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("a read-only directory is writable by root")
	}
	root := t.TempDir()
	state := filepath.Join(root, "RESEARCH-STATE.md")
	if err := os.WriteFile(state, []byte("# T\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o555); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(root, 0o755) }()
	s, out, errb := stdio(root)
	if rc := Run([]string{root, "--sync-state"}, s); rc != 1 || out.Len() != 0 || !strings.HasPrefix(errb.String(), "sync-state: ERROR: "+state+": rewriting the envelope failed (") || !strings.HasSuffix(errb.String(), ") — file NOT modified.\n") {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
	if b, _ := os.ReadFile(state); string(b) != "# T\n" {
		t.Errorf("the state file changed: %q", b)
	}
	ents, _ := os.ReadDir(root)
	if len(ents) != 1 {
		t.Errorf("leftover entries: %v", ents)
	}
}

func TestReadlinkF(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	real := filepath.Join(root, "real.md")
	if err := os.WriteFile(real, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real.md", filepath.Join(root, "link.md")); err != nil {
		t.Fatal(err)
	}
	s, _, _ := stdio(root)
	c := &ctx{s: s}
	if got := c.readlinkF("link.md"); got != real {
		t.Errorf("relative link = %q, want %q", got, real)
	}
	if got := c.readlinkF(filepath.Join(root, "link.md")); got != real {
		t.Errorf("absolute link = %q, want %q", got, real)
	}
	if got := c.readlinkF("missing/x.md"); got != "missing/x.md" {
		t.Errorf("unresolvable path = %q", got)
	}
}

func TestBlockedOpenUnreadableNamesTheFile(t *testing.T) {
	s, _, errb := stdio(t.TempDir())
	c := &ctx{s: s, state: "/nonexistent/RESEARCH-STATE.md"}
	if n, rc := c.blockedOpen(); n != 0 || rc != 2 || errb.String() != "blocked-rows: state file absent or unreadable: /nonexistent/RESEARCH-STATE.md\n" {
		t.Errorf("n=%d rc=%d stderr=%q", n, rc, errb.String())
	}
	errb.Reset()
	c.state = ""
	c.blockedOpen()
	if errb.String() != "blocked-rows: state file absent or unreadable: <empty path>\n" {
		t.Errorf("empty path: %q", errb.String())
	}
}
