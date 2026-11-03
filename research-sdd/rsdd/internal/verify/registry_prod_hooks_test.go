package verify

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Each productionHooks method answers from core/hookwiring for a sandbox; the literals keep the mapping (field
// order, ok flags) pinned when the differential is compiled out (nodiff, the mutation run).
func TestProductionHooksAnswerFromHookwiring(t *testing.T) {
	k := newVRKit(t)
	k.put("w/.git/HEAD", "x\n")
	k.put("w/.claude/hooks/retro-gate-stop.sh", "#!/bin/sh\n")
	k.put("w/.claude/settings.json", `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"`+k.home+`/w/.claude/hooks/gone.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"`+k.home+`/w/.claude/hooks/retro-gate-stop.sh"}]}]}}`)
	k.put("u/.claude/settings.json", `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"elsewhere.sh"}]}]}}`)
	k.write("hist/", "")
	e := map[string]string{"HOME": k.home, "RSDD_HOOK_WIRING_CEILING": k.root, "RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(k.root, "hist")}
	h := newProductionHooks(cli.Stdio{Env: func(key string) string { return e[key] }, Cwd: k.root})
	eq := func(name, got string, ok bool, want string) {
		t.Helper()
		if !ok || got != want {
			t.Errorf("%s = %q ok=%v, want %q ok=true", name, got, ok, want)
		}
	}
	w, ok := h.StopWiringState(filepath.Join(k.home, "w"))
	eq("wiring w", w, ok, "wired")
	w, ok = h.StopWiringState(filepath.Join(k.home, "u"))
	eq("wiring u", w, ok, "unwired")
	w, ok = h.StopWiringState(filepath.Join(k.home, "none"))
	eq("wiring none", w, ok, "absent-settings")
	s, ok := h.StopScriptState(filepath.Join(k.home, "w"))
	eq("script w", s, ok, "present")
	l, ok := h.StopLaunchState(filepath.Join(k.home, "w"))
	eq("launch w", l, ok, "no-sessions")
	rows, ok := h.WiredExecReport(filepath.Join(k.home, "w"))
	if !ok || len(rows) == 0 {
		t.Fatalf("wired-exec rows = %+v ok=%v, want findings", rows, ok)
	}
	found := false
	for _, r := range rows {
		if strings.HasSuffix(r.Path, "/w/.claude/hooks/gone.sh") && r.Kind != "" && r.Detail != "" {
			found = true
		}
	}
	if !found {
		t.Errorf("wired-exec rows = %+v, want a finding for gone.sh with kind, path and detail", rows)
	}
}
