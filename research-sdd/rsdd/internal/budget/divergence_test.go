package budget

import (
	"path/filepath"
	"strings"
	"testing"
)

// Divergences from the frozen script, each declared in the package doc (session.go) and pinned here: this is
// what the Go command does where the script did something else.

func TestDivergenceJqNotNeeded(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	bin := sb.mkbin("bin-nojq", "jq")
	env := sb.environ("PATH=" + bin)
	l := sb.legacy(env, sb.target("over"))
	if !strings.Contains(l.stdout, "state: degraded (jq unavailable; no hook was run)") {
		t.Fatalf("the oracle must report the missing jq, got %q", l.stdout)
	}
	g := sb.golang(env, sb.target("over"))
	if !has(g.stdout, `^aggregate: 9000 chars .*OVER BUDGET`) || !has(g.stdout, `^state: ok \(3 hook runs, 0 truncated, 0 timed-out\)`) || g.rc != 0 {
		t.Errorf("without jq the Go command measures anyway: %+v", g)
	}
}

func TestDivergenceNoLocaleProbe(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	// a C locale: wc -m would count bytes and the script degraded; the Go count is of decoded text regardless
	g := sb.golang(sb.environ("LC_ALL=C", "LANG=C"), sb.target("utf8"))
	if !has(g.stdout, `hook\[1\] chars=3 status=ok`) || has(g.stdout, `no-utf8-locale`) {
		t.Errorf("got %q", g.stdout)
	}
}

func TestDivergenceSettingsAndSelection(t *testing.T) {
	sb := newSbx(t)
	env := sb.environ()
	hook := `{"type":"command","command":"printf x"}`
	for name, c := range map[string]struct{ body, want string }{
		"two objects":               {`{} {"hooks":{"SessionStart":[{"hooks":[` + hook + `]}]}}`, "state: degraded (settings.json is not a readable JSON object; no hook was run)"},
		"SessionStart is an object": {`{"hooks":{"SessionStart":{"a":{"hooks":[` + hook + `]}}}}`, "state: empty-input (no SessionStart command hook matches"},
		"entry hooks is an object":  {`{"hooks":{"SessionStart":[{"hooks":{"a":` + hook + `}}]}}`, "state: empty-input (no SessionStart command hook matches"},
	} {
		d := sb.mkTarget(strings.ReplaceAll(name, " ", "-"), c.body, nil)
		if g := sb.golang(env, d); !strings.Contains(g.stdout, c.want) || g.rc != 0 {
			t.Errorf("%s: want %q, got %+v", name, c.want, g)
		}
	}
}

func TestDivergenceHookOutput(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	d := sb.mkTarget("div-output", `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[`+
		`{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/surrogate.sh"},`+
		`{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/two-objects.sh"},`+
		`{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/hso-string.sh"},`+
		`{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/exponent.sh"},`+
		`{"type":"command","command":"sleep 30","timeout":99999999999999999999}`+
		`]}]}}`, map[string]string{
		"surrogate.sh":   `printf '{"systemMessage":"\\ud800x"}'`,
		"two-objects.sh": `printf '{"systemMessage":"ab"}\n{"systemMessage":"cd"}\n'`,
		"hso-string.sh":  `printf '{"hookSpecificOutput":"str","systemMessage":"abc"}'`,
		"exponent.sh":    `printf '{"systemMessage":1E2}'`,
	})
	o := sb.golang(sb.environ("RSDD_BUDGET_HOOK_TIMEOUT=1"), d)
	for _, re := range []string{
		`hook\[1\] chars=2 status=ok`,  // a lone-surrogate escape: decoded with U+FFFD, not counted as plain text
		`hook\[2\] chars=46 status=ok`, // several JSON values: plain text (the script's jq would have broken its arithmetic)
		`hook\[3\] chars=3 status=ok`,  // a hookSpecificOutput that is not an object counts 0, silently
		`hook\[4\] chars=3 status=ok`,  // 1E2 keeps its spelling (jq prints 1E+2)
		`hook\[5\] chars=n/a status=degraded\(timeout 1s: this script's cap; the hook allows 99999999999999999999s\)`,
	} {
		if !has(o.stdout, re) {
			t.Errorf("no line /%s/ in\n%s", re, o.stdout)
		}
	}
	if o.stderr != "" {
		t.Errorf("the script's stray `[: integer expression expected` is not reproduced; stderr=%q", o.stderr)
	}
}

func TestDivergencePiToolbeltFallback(t *testing.T) {
	needNodeTS(t)
	sb := newSbx(t)
	card := sb.target("pi-card")
	env := sb.piEnv()
	with := sb.golang(env, "--harness", "pi", card)
	if !has(with.stdout, `^aggregate\[pi\]: `) {
		t.Fatalf("baseline run failed: %q", with.stdout)
	}
	// run through the command table WITHOUT --toolbelt, the way `rsdd budget session` is run directly
	realKit, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	run := func(extra ...string) observed {
		var o observed
		e := sb.piEnv(extra...)
		o.stdout, o.stderr, o.rc = runNoToolbelt(e, sb.cwd, "--harness", "pi", card)
		return o
	}
	if got := run("RESEARCH_SDD_KIT=" + realKit); got.stdout != with.stdout || got.rc != 0 {
		t.Errorf("a resolved kit must find the helper:\n--- with --toolbelt\n%s--- fallback\n%s", with.stdout, got.stdout)
	}
	none := run("RESEARCH_SDD_KIT=" + sb.root + "/no-such-kit")
	if !has(none.stdout, `pi: DEGRADED — measuring helper not found: `) || has(none.stdout, `aggregate\[pi\]`) || none.rc != 0 {
		t.Errorf("an unknown toolbelt is a typed degrade, never a zero: %+v", none)
	}
}
