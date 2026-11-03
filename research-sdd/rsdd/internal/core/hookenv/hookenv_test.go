package hookenv

import (
	"bytes"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func TestJQStringEscapes(t *testing.T) {
	cases := map[string]string{
		"plain":        `"plain"`,
		`q"b\`:         `"q\"b\\"`,
		"\b\f\n\r\t":   `"\b\f\n\r\t"`,
		"\x00\x01\x1f": `"\u0000\u0001\u001f"`,
		"\x7f":         `"\u007f"`,
		"é日本😀":         "\"é日本😀\"",
		"<>& ":         "\"<>& \"",
		"a\xffb":       "\"a�b\"",
		"\xe2\x82":     "\"��\"",
		"":             `""`,
	}
	for in, want := range cases {
		if got := JQString(in); got != want {
			t.Errorf("JQString(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestWriteSessionStartShape(t *testing.T) {
	var b bytes.Buffer
	WriteSessionStart(&b, "h\nx")
	want := "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": \"h\\nx\"\n  }\n}\n"
	if b.String() != want {
		t.Errorf("got %q, want %q", b.String(), want)
	}
}

func TestGuardPanicBecomesOperational(t *testing.T) {
	var buf bytes.Buffer
	buf.WriteString("before\n")
	rc := Guard(&buf, func() int { panic("boom") })
	if rc != cli.ExitOperational {
		t.Fatalf("rc=%d, want %d", rc, cli.ExitOperational)
	}
	if got := buf.String(); got != "before\nrsdd: internal-error: boom\n" {
		t.Errorf("buf = %q", got)
	}
}

func TestGuardPassesThrough(t *testing.T) {
	for _, want := range []int{0, 1, 7} {
		var buf bytes.Buffer
		if rc := Guard(&buf, func() int { return want }); rc != want || buf.Len() != 0 {
			t.Errorf("rc=%d buf=%q, want %d and empty", rc, buf.String(), want)
		}
	}
}

func TestGuardDoesNotRepanic(t *testing.T) {
	var buf bytes.Buffer
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("Guard re-panicked: %v", p)
		}
	}()
	if rc := Guard(&buf, func() int { panic(strings.NewReader("")) }); rc != cli.ExitOperational {
		t.Errorf("rc=%d", rc)
	}
	if rc := Guard(&buf, func() int { panic(nil) }); rc != cli.ExitOperational {
		t.Errorf("nil panic rc=%d", rc)
	}
}
