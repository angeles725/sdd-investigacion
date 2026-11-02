package stageissues

import (
	"regexp"
	"strings"
	"testing"
	"unicode/utf8"
)

// JSON cannot carry a byte that is not UTF-8, and the cases include Latin-1 titles. A golden therefore stores such
// a byte b as the private-use rune U+F700+b (no case uses a real U+F7xx character) and decodes it back.
func packBytes(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && w == 1 {
			b.WriteRune(0xF700 + rune(s[i]))
		} else {
			b.WriteString(s[i : i+w])
		}
		i += w
	}
	return b.String()
}

func unpackBytes(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0xF700 && r <= 0xF7FF {
			b.WriteByte(byte(r - 0xF700))
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func mapState(m map[string]string, f func(string) string) map[string]string {
	if m == nil {
		return nil
	}
	out := map[string]string{}
	for k, v := range m {
		out[k] = f(v)
	}
	return out
}

func (r result) packed() result {
	return result{RC: r.RC, Stdout: packBytes(r.Stdout), Stderr: packBytes(r.Stderr), GHLog: packBytes(r.GHLog), State: mapState(r.State, packBytes)}
}

func (r result) unpacked() result {
	return result{RC: r.RC, Stdout: unpackBytes(r.Stdout), Stderr: unpackBytes(r.Stderr), GHLog: unpackBytes(r.GHLog), State: mapState(r.State, unpackBytes)}
}

// reGawkNoise is the exact shape of gawk's own locale warning, as the legacy awk programs emit it on invalid UTF-8
// input under a UTF-8 locale. INTENDED DIVERGENCE: legacy-only gawk locale noise that the Go port does not
// reproduce. It is stripped on the LEGACY side only, and no other stderr line is touched.
var reGawkNoise = regexp.MustCompile(`^awk: cmd\. line:[0-9]+: \(FILENAME=[^ )]*( FNR=[0-9]+)?\) warning: Invalid multibyte data detected\. There may be a mismatch between your data and your locale\n?$`)

func dropGawkNoise(s string) string {
	var out []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if reGawkNoise.MatchString(l) {
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "")
}

func TestDropGawkNoiseIsNarrow(t *testing.T) {
	noise := "awk: cmd. line:5: (FILENAME=/b/r.md FNR=8) warning: Invalid multibyte data detected. There may be a mismatch between your data and your locale\n"
	keep := []string{
		"awk: cmd. line:5: fatal: something else\n",
		"warning: Invalid multibyte data detected. There may be a mismatch between your data and your locale\n",
		"WARN: awk: cmd. line:5: (FILENAME=x FNR=1) warning: Invalid multibyte data detected. There may be a mismatch between your data and your locale\n",
		"awk: cmd. line:5: (FILENAME=x FNR=1) warning: Invalid multibyte data detected. extra\n",
		"unclassifiable-row: row 1 has no usable title\n",
	}
	if got := dropGawkNoise(noise + noise); got != "" {
		t.Errorf("noise lines were kept: %q", got)
	}
	for _, k := range keep {
		if got := dropGawkNoise(noise + k + noise); got != k {
			t.Errorf("filter touched or lost %q: got %q", k, got)
		}
	}
}

func TestPackBytesRoundTrip(t *testing.T) {
	for _, s := range []string{"", "plain", "caf\xe9 x", "\xb0\xb0", "ñ and \xff", "é"} {
		if got := unpackBytes(packBytes(s)); got != s {
			t.Errorf("round trip of %q gave %q", s, got)
		}
		if !utf8.ValidString(packBytes(s)) {
			t.Errorf("packBytes(%q) is not valid UTF-8", s)
		}
	}
}

func TestStripCLIDegradedIsNarrow(t *testing.T) {
	l := cliDegradedLine
	for _, c := range []struct {
		name string
		rc   int
		in   string
		want string
	}{
		{"rc3 last line stripped", 3, "a\n" + l, "a\n"},
		{"rc3 text elsewhere kept", 3, l + "a\n", l + "a\n"},
		{"rc3 other degraded line kept", 3, "DEGRADED: gh missing\n", "DEGRADED: gh missing\n"},
		{"rc2 last line kept", 2, "a\n" + l, "a\n" + l},
		{"rc1 last line kept", 1, l, l},
		{"rc0 last line kept", 0, "a\n" + l, "a\n" + l},
	} {
		if got := stripCLIDegraded(c.rc, c.in); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

// reBashRuntimeNoise is the exact shape of the bash runtime diagnostic the legacy script prints for an out-of-range
// STAGE_RETRO_ISSUES_LIST_LIMIT. INTENDED DIVERGENCE, case apply/limit-huge only: bash `[: integer expression
// expected` runtime noise with script line numbers, which the Go port does not reproduce. Stripped on the legacy
// side of that one case; the rest of its stderr, its stdout and its exit code are compared byte for byte.
var reBashRuntimeNoise = regexp.MustCompile(`^[^\n]*/stage-retro-issues\.sh: line [0-9]+: \[: [0-9]+: integer expression expected\n$`)

func dropBashNoise(name, s string) string {
	if name != "apply/limit-huge" {
		return s
	}
	var out []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if reBashRuntimeNoise.MatchString(l) {
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "")
}

func TestDropBashNoiseIsNarrow(t *testing.T) {
	n := "@BOX@/research-sdd/toolbelt/stage-retro-issues.sh: line 1026: [: 99999999999999999999: integer expression expected\n"
	if got := dropBashNoise("apply/limit-huge", n+"x\n"+n); got != "x\n" {
		t.Errorf("limit-huge: got %q", got)
	}
	if got := dropBashNoise("apply/limit-text", n); got != n {
		t.Errorf("another case must not be filtered: got %q", got)
	}
	other := "stage-retro-issues.sh: line 5: foo: command not found\n"
	if got := dropBashNoise("apply/limit-huge", other); got != other {
		t.Errorf("other bash errors must be kept: got %q", got)
	}
}
