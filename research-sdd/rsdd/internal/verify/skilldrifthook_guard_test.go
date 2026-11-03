//go:build unix

package verify

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// A panic inside the skill-drift hook must still reach the session as an envelope (CLAUDE.md §7, kit issue
// #2610). The seam is the environment lookup, which every run reads (the drift check and then the install
// --verify command), so the panic is always reached.
func TestSkillDriftHookPanicStillEmitsEnvelope(t *testing.T) {
	w := hookWorld(t)
	var out, errb bytes.Buffer
	s := w.stdio(&out, &errb)
	s.Env = func(string) string { panic("boom in the skill-drift hook") }
	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("the panic escaped the hook: %v", p)
			}
		}()
		if rc := runSkillDriftHookWith([]string{filepath.Join(w.kit, "toolbelt")}, s, defaultHookBudgets()); rc != 0 {
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
	if !strings.HasPrefix(v.H.Ctx, hdrCannotRun) || !strings.Contains(v.H.Ctx, "rsdd: internal-error: boom in the skill-drift hook") {
		t.Errorf("context %q", v.H.Ctx)
	}
}
