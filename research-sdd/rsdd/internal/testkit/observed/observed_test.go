package observed

import (
	"fmt"
	"strings"
	"testing"
)

type recorder struct{ msgs []string }

func (r *recorder) Helper() {}
func (r *recorder) Errorf(format string, args ...any) {
	r.msgs = append(r.msgs, fmt.Sprintf(format, args...))
}

func TestNew(t *testing.T) {
	if got := New("out", "err", 3); got != (Run{Stdout: "out", Stderr: "err", RC: 3}) {
		t.Fatalf("New = %+v", got)
	}
}

func TestSameEqualRunsPass(t *testing.T) {
	r := &recorder{}
	Same(r, "x", New("o", "e", 2), New("o", "e", 2))
	if len(r.msgs) != 0 {
		t.Fatalf("equal runs reported %q", r.msgs)
	}
}

// Each of the three fields must fail the comparison on its own, and the message must carry both sides.
func TestSameFailsOnEachField(t *testing.T) {
	base := New("o", "e", 0)
	for name, got := range map[string]Run{"stdout": New("x", "e", 0), "stderr": New("o", "x", 0), "rc": New("o", "e", 1)} {
		r := &recorder{}
		Same(r, "cmp", base, got)
		if len(r.msgs) != 1 || !strings.Contains(r.msgs[0], "cmp differs from the legacy script") || !strings.Contains(r.msgs[0], "go rc=") {
			t.Errorf("%s: messages %q", name, r.msgs)
		}
	}
}
