package hook

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Hand-written expectations (no bash oracle, so they also run under the nodiff tag that the mutation run uses).
// They pin the contract of templates/hook-kit-run.sh: pass-through, typed degraded lines, fail-closed guard.

func kitRoot(t *testing.T) (root string, env map[string]string) {
	t.Helper()
	root = t.TempDir()
	probe := "#!/usr/bin/env bash\ncat\necho \"ran:$*\"\necho \"err:$*\" >&2\nexit 7\n"
	for p, body := range map[string]string{"kit/toolbelt/probe.sh": probe, "kit/templates/hook-pretool-pkill-guard.sh": "#!/usr/bin/env bash\necho GUARD-RAN\n"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, p), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "home"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root, map[string]string{"HOME": filepath.Join(root, "home")}
}

type got struct {
	out, err string
	rc       int
}

func run(env map[string]string, stdin string, args ...string) got {
	var o, e bytes.Buffer
	rc := KitRun(args, cli.Stdio{In: strings.NewReader(stdin), Out: &o, Err: &e, Env: func(k string) string { return env[k] }})
	return got{o.String(), e.String(), rc}
}

func TestPassThrough(t *testing.T) {
	root, env := kitRoot(t)
	env["RESEARCH_SDD_KIT"] = filepath.Join(root, "kit")
	r := run(env, "in-bytes", "toolbelt/probe.sh", "a", "b c")
	if r != (got{"in-bytes" + "ran:a b c\n", "err:a b c\n", 7}) {
		t.Errorf("stdin, args, both streams and rc 7 must pass through: %+v", r)
	}
}

// A child killed by a signal is reported the way a shell reports it: 128+n.
func TestSignalExitCode(t *testing.T) {
	root, env := kitRoot(t)
	env["RESEARCH_SDD_KIT"] = filepath.Join(root, "kit")
	if err := os.WriteFile(filepath.Join(root, "kit", "toolbelt", "die.sh"), []byte("#!/usr/bin/env bash\nkill -9 $$\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if r := run(env, "", "toolbelt/die.sh"); r.rc != 137 {
		t.Errorf("SIGKILL child: rc=%d, want 137 (%+v)", r.rc, r)
	}
}

// A bash that cannot be started is a typed failure with exit 127, never an allow.
func TestNoBash(t *testing.T) {
	root, env := kitRoot(t)
	env["RESEARCH_SDD_KIT"] = filepath.Join(root, "kit")
	t.Setenv("PATH", filepath.Join(root, "empty"))
	r := run(env, "", "toolbelt/probe.sh")
	if r.rc != 127 || r.out != "" || !strings.HasPrefix(r.err, "kit-run: DEGRADED: cannot start bash (") || !strings.HasSuffix(r.err, "); toolbelt/probe.sh did NOT run\n") {
		t.Errorf("missing bash: %+v", r)
	}
}

func TestResolutionOrderAndWarning(t *testing.T) {
	root, env := kitRoot(t)
	launcher := filepath.Join(root, "home", ".claude", "CLAUDE.md")
	if err := os.MkdirAll(filepath.Dir(launcher), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(launcher, []byte("Kit path: `~/../kit`\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	env["RESEARCH_SDD_KIT"] = filepath.Join(root, "nope")
	r := run(env, "", "toolbelt/probe.sh")
	warn := "kit-run: DEGRADED: RESEARCH_SDD_KIT=" + filepath.Join(root, "nope") + " invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n"
	if r.rc != 7 || !strings.HasPrefix(r.err, warn) || r.out != "ran:\n" {
		t.Errorf("invalid env must warn then fall through to the launcher file: %+v", r)
	}
}

func TestTypedFailures(t *testing.T) {
	root, env := kitRoot(t)
	kitDir := filepath.Join(root, "kit")
	cases := []struct {
		name   string
		env    map[string]string
		args   []string
		stderr string
	}{
		{"no args", env, nil, "kit-run: DEGRADED: no script given\n"},
		{"empty rel", env, []string{""}, "kit-run: DEGRADED: no script given\n"},
		{"unresolved", env, []string{"toolbelt/probe.sh"}, "kit-run: DEGRADED: research-sdd kit not found (set RESEARCH_SDD_KIT); toolbelt/probe.sh did NOT run\n"},
		{"missing", map[string]string{"HOME": env["HOME"], "RESEARCH_SDD_KIT": kitDir}, []string{"toolbelt/no.sh"}, "kit-run: DEGRADED: " + kitDir + "/toolbelt/no.sh is missing; toolbelt/no.sh did NOT run\n"},
		{"dotdot", env, []string{"../x.sh"}, "kit-run: DEGRADED: script path '../x.sh' must be kit-relative without '..'; ../x.sh did NOT run\n"},
		{"absolute", env, []string{"/x.sh"}, "kit-run: DEGRADED: script path '/x.sh' must be kit-relative without '..'; /x.sh did NOT run\n"},
	}
	for _, c := range cases {
		if r := run(c.env, "stdin", c.args...); r != (got{"", c.stderr, 1}) {
			t.Errorf("%s: %+v, want rc 1 stderr %q and no stdout", c.name, r, c.stderr)
		}
	}
}

// Fail-closed: the pkill guard that cannot run asks for a pkill/pgrep payload and passes the rest; it never allows
// a pkill payload silently and never fails the tool call for another one.
func TestGuardFailsClosed(t *testing.T) {
	_, env := kitRoot(t)
	why := "research-sdd kit not found (set RESEARCH_SDD_KIT)"
	reason := "kit-run pkill-guard DEGRADED: " + why + "; this command mentions pkill/pgrep and cannot be checked for a self-matching -f pattern. Approve only if the pattern is bracket-escaped or uses -x/a PID."
	want := "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"PreToolUse\",\n    \"permissionDecision\": \"ask\",\n    \"permissionDecisionReason\": \"" + reason + "\"\n  }\n}\n"
	for _, rel := range []string{"templates/hook-pretool-pkill-guard.sh", "research-sdd/templates/hook-pretool-pkill-guard.sh"} {
		for _, in := range []string{`{"command":"pkill -f x"}`, `pgrep`, "{bad pkill"} {
			if r := run(env, in, rel); r != (got{want, "", 0}) {
				t.Errorf("%s %q: %+v, want the ask decision", rel, in, r)
			}
		}
		if r := run(env, `{"command":"ls"}`, rel); r != (got{}) {
			t.Errorf("%s non-pkill payload: %+v, want silent pass", rel, r)
		}
	}
	if r := run(env, "pkill", "templates/other.sh"); r.rc != 1 || r.out != "" {
		t.Errorf("only the guard script fails closed to ask: %+v", r)
	}
	if r := run(env, "pkill", ""); r.rc != 1 || r.out != "" {
		t.Errorf("an empty script is the usage failure even for the guard stdin: %+v", r)
	}
}

func TestGuardResolvedRunsTheGuard(t *testing.T) {
	root, env := kitRoot(t)
	env["RESEARCH_SDD_KIT"] = filepath.Join(root, "kit")
	if r := run(env, "pkill", "templates/hook-pretool-pkill-guard.sh"); r != (got{"GUARD-RAN\n", "", 0}) {
		t.Errorf("a resolved guard must be executed: %+v", r)
	}
}

func TestJQStringEncoding(t *testing.T) {
	cases := map[string]string{
		"a<b>&c": "a<b>&c", "tab\tnl\ncr\r": `tab\tnl\ncr\r`, "\x01\x1f": `\u0001\u001f`, "\x7f": `\u007f`,
		" é": " é", "q\"b\\": `q\"b\\`, "\b\f": `\b\f`, "bad\xffbyte": "bad�byte",
	}
	for in, want := range cases {
		if g := jqString(in); g != `"`+want+`"` {
			t.Errorf("jqString(%q) = %s", in, g)
		}
	}
}
