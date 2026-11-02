package hookwiring

import (
	"path/filepath"
	"testing"
)

// launch-state (kit issue #2357) is batch from the start: one state per line in argument order, so a fleet loop pays
// one fork. RSDD_CLAUDE_PROJECTS_DIR, CLAUDE_CONFIG_DIR and HOME reach the predicate through Stdio.Env.
func TestLaunchStateCommand(t *testing.T) {
	r, _ := sandbox(t)
	hist := filepath.Join(r, "hist")
	a, b := filepath.Join(r, "a"), filepath.Join(r, "b")
	transcript(t, hist, a, "s.jsonl")
	env := map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": hist}
	out, errOut, code := run(t, r, env, "hook", "launch-state", a, b, a)
	if out != "launched\nno-sessions\nlaunched\n" || errOut != "" || code != 0 {
		t.Errorf("batch = (%q, %q, %d)", out, errOut, code)
	}
	if out, _, _ := run(t, r, env, "hook", "launch-state", b); out != "no-sessions\n" {
		t.Errorf("single = %q", out)
	}
	if out, _, _ := run(t, r, nil, "hook", "launch-state", a, b); out != "unknown\nunknown\n" {
		t.Errorf("no history root = %q, want one unknown per target", out)
	}
	// a relative target is taken from the cwd
	if out, _, _ := run(t, r, env, "hook", "launch-state", "a"); out != "launched\n" {
		t.Errorf("relative = %q", out)
	}
}

func TestWiredExecCommand(t *testing.T) {
	r, _ := sandbox(t)
	target, home := execFixture(t, r)
	wireSettings(t, target, stopSettings(t, pdir+"/noexec"))
	out, errOut, code := run(t, r, map[string]string{envHome: home}, "hook", "wired-exec", target)
	if want := "not-executable\t" + target + "/.claude/hooks/noexec\tStop\n"; out != want || errOut != "" || code != 0 {
		t.Errorf("wired-exec = (%q, %q, %d), want (%q, \"\", 0)", out, errOut, code, want)
	}
	// HOME reaches the resolver through Stdio.Env
	wireSettings(t, target, stopSettings(t, "$HOME/h/noexec"))
	if out, _, _ := run(t, r, map[string]string{envHome: home}, "hook", "wired-exec", target); out != "not-executable\t"+home+"/h/noexec\tStop\n" {
		t.Errorf("HOME = %q", out)
	}
	// nothing to report prints nothing and exits 0
	wireSettings(t, target, stopSettings(t, pdir+"/ok-exec"))
	if out, errOut, code := run(t, r, nil, "hook", "wired-exec", target); out != "" || errOut != "" || code != 0 {
		t.Errorf("clean target = (%q, %q, %d)", out, errOut, code)
	}
}
