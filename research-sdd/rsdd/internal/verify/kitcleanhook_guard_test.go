//go:build unix

package verify

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// A panic inside the kit-clean check must still reach the session as the could-not-run envelope (CLAUDE.md §7,
// kit issue #2610). The seam is the environment lookup: gitRunner reads it before the first git call, so it is
// always reached.
func TestKitCleanHookPanicStillEmitsEnvelope(t *testing.T) {
	sb := newSandbox(t)
	d := sb.repo("p", true, nil)
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:   func(string) string { panic("boom in the kit-clean check") },
		Clock: func() time.Time { return time.Unix(0, 0) },
		Cwd:   sb.home,
	}
	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("the panic escaped the hook: %v", p)
			}
		}()
		if rc := RunKitCleanHook([]string{d}, s); rc != 0 {
			t.Fatalf("rc=%d, want 0 (a hook never fails the session)", rc)
		}
	}()
	var v struct {
		H struct {
			Ctx string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal(out.Bytes(), &v); err != nil {
		t.Fatalf("no SessionStart envelope (%v): %q", err, out.String())
	}
	if !strings.HasPrefix(v.H.Ctx, hdrInternal) || !strings.Contains(v.H.Ctx, "rsdd: internal-error: boom in the kit-clean check") {
		t.Errorf("context %q", v.H.Ctx)
	}
}
