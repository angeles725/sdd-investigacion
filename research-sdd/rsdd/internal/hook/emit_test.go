//go:build unix

package hook

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func runEmit(args ...string) (stdout, stderr string, rc int) {
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" }, Clock: time.Now, Cwd: "/"}
	rc = cli.Run(Commands, append([]string{"hook", "emit"}, args...), s)
	return out.String(), errb.String(), rc
}

func envelope(ctx string) string {
	return "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": " + ctx + "\n  }\n}\n"
}

func TestEmitEnvelope(t *testing.T) {
	cases := []struct {
		name string
		args []string
		ctx  string // the JSON string literal
	}{
		{"headered", []string{"HDR line:", "body one"}, `"HDR line:\nbody one"`},
		{"headerless", []string{"just the body"}, `"just the body"`},
		{"no argument", nil, `""`},
		{"only two arguments count", []string{"H", "B", "ignored"}, `"H\nB"`},
		{"empty header keeps the separator", []string{"", "B"}, `"\nB"`},
		{"flags are text", []string{"-n", "--help"}, `"-n\n--help"`},
		{"awkward body", []string{"H", "line \"one\"\nback\\slash 100% %s\n\tTabbed"}, `"H\nline \"one\"\nback\\slash 100% %s\n\tTabbed"`},
		{"control characters", []string{"\x01\x08\x0c\x1f\x7f"}, `"\u0001\b\f\u001f\u007f"`},
		{"non-ascii stays raw", []string{"é — 😀 <&> \u2028"}, "\"é — 😀 <&> \u2028\""},
		{"invalid utf-8 is U+FFFD", []string{"x\xffy"}, "\"x\uFFFDy\""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, rc := runEmit(c.args...)
			if stdout != envelope(c.ctx) || stderr != "" || rc != 0 {
				t.Errorf("rc=%d stderr=%q\n got %q\nwant %q", rc, stderr, stdout, envelope(c.ctx))
			}
		})
	}
}

// The sourced function and the command must print the same bytes for the same arguments: hook-emit.sh as it was
// before the port (testdata/legacy, still the body of the live lib/hook-emit.sh), run with jq on PATH.
func TestEmitMatchesLegacyFunction(t *testing.T) {
	var path []string
	for _, tool := range []string{"bash", "jq"} {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Fatalf("%s is required (a skipped differential proves nothing): %v", tool, err)
		}
		path = append(path, filepath.Dir(p))
	}
	lib, err := filepath.Abs("testdata/legacy/hook-emit.sh")
	if err != nil {
		t.Fatal(err)
	}
	vectors := [][]string{
		nil, {""}, {"b"}, {"h", "b"}, {"h", "b", "extra"}, {"", "b"}, {"h", ""}, {"-n"}, {"--"}, {"-e", "a\\nb"},
		{"HDR line:", "body one"}, {"H", "line \"one\"\nback\\slash 100% %s\n\tTabbed"},
		{"ctl", "\x01\x02\x08\x0b\x0c\x1b\x1f del \x7f"}, {"é — · § 😀 \u2028 \u2029 <&>"}, {"multi\n\nline\n"},
		{"H", "trailing newlines\n\n"}, {"x\xffy"}, {"bad \xc3("}, {"\r\n"}, {strings.Repeat("long ", 4000)},
	}
	for _, v := range vectors {
		cmd := exec.Command("bash", append([]string{"-c", `. "$1"; shift; rsdd_hook_emit "$@"`, "_", lib}, v...)...)
		cmd.Env = []string{"PATH=" + strings.Join(path, ":"), "LC_ALL=C"}
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			t.Fatalf("legacy %q: %v", v, err)
		}
		stdout, _, rc := runEmit(v...)
		if stdout != out.String() || rc != 0 {
			t.Errorf("args %q (rc=%d):\n legacy %q\n     go %q", v, rc, out.String(), stdout)
		}
	}
}
