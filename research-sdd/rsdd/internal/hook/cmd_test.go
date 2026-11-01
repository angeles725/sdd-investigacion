package hook

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// run dispatches one `rsdd hook ...` invocation through the real table.
func run(t *testing.T, cwd string, env map[string]string, args ...string) (out, errOut string, code int) {
	t.Helper()
	var o, e bytes.Buffer
	s := cli.Stdio{
		In:    strings.NewReader(""),
		Out:   &o,
		Err:   &e,
		Env:   func(k string) string { return env[k] },
		Clock: func() time.Time { return time.Unix(0, 0) },
		Cwd:   cwd,
	}
	code = cli.Run(Commands, args, s)
	return o.String(), e.String(), code
}

func TestCommandsValidate(t *testing.T) {
	if err := cli.Validate(Commands); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"abspath", "git-root", "wiring-state", "script-state"} {
		found := false
		for _, c := range Commands {
			if c.Group == "hook" && c.Name == name {
				found = true
			}
		}
		if !found {
			t.Errorf("hook %s is not registered", name)
		}
	}
}

func TestWiringStateCommand(t *testing.T) {
	r, _ := sandbox(t)
	d := settingsAt("w", stopWired)(t, r)
	env := map[string]string{envCeiling: filepath.Dir(r)}
	out, errOut, code := run(t, r, env, "hook", "wiring-state", d)
	if out != "wired\n" || errOut != "" || code != 0 {
		t.Errorf("wiring-state = (%q, %q, %d), want (\"wired\\n\", \"\", 0)", out, errOut, code)
	}
	// the ceiling reaches the walk-up through Stdio.Env: an enclosing repo is seen only without it
	gitInit(t, filepath.Join(r, "encl"))
	n := settingsAt("encl/sub/t", stopWired)(t, r)
	if out, _, _ := run(t, r, map[string]string{envCeiling: filepath.Join(r, "encl", "sub")}, "hook", "wiring-state", n); out != "wired\n" {
		t.Errorf("with ceiling = %q, want wired", out)
	}
	if out, _, _ := run(t, r, map[string]string{envCeiling: ""}, "hook", "wiring-state", n); out != "wired-off-root\n" {
		t.Errorf("without ceiling = %q, want wired-off-root", out)
	}
}

func TestWiringStateCommandRelativeTargetUsesCwd(t *testing.T) {
	r, _ := sandbox(t)
	settingsAt("proj", stopWired)(t, r)
	out, _, code := run(t, r, map[string]string{envCeiling: filepath.Dir(r)}, "hook", "wiring-state", "proj")
	if out != "wired\n" || code != 0 {
		t.Errorf("relative target = (%q, %d), want (wired, 0)", out, code)
	}
}

func TestScriptStateCommand(t *testing.T) {
	r, _ := sandbox(t)
	d := withSettings("s", nil, func(d string) string { return st(d + "/gone.sh/retro-gate") })(t, r)
	out, _, code := run(t, r, nil, "hook", "script-state", d)
	if out != "missing\n" || code != 0 {
		t.Errorf("script-state = (%q, %d), want (missing, 0)", out, code)
	}
	home := filepath.Join(r, "h")
	writeFile(t, filepath.Join(home, "hk", "retro-gate.sh"), "")
	d2 := withSettings("s2", nil, fixed(st(`$HOME/hk/retro-gate.sh`)))(t, r)
	if out, _, _ := run(t, r, map[string]string{envHome: home}, "hook", "script-state", d2); out != "present\n" {
		t.Errorf("HOME reaches the resolver through Stdio.Env: got %q, want present", out)
	}
}

func TestAbsPathCommand(t *testing.T) {
	out, errOut, code := run(t, "/w", nil, "hook", "abspath", "a/../b/./c\nd")
	if out != "/w/b/c\nd\n" || errOut != "" || code != 0 {
		t.Errorf("abspath = (%q, %q, %d)", out, errOut, code)
	}
}

func TestGitRootCommand(t *testing.T) {
	r, _ := sandbox(t)
	gitInit(t, filepath.Join(r, "p"))
	mkdirs(t, filepath.Join(r, "p", "n"))
	env := map[string]string{envCeiling: filepath.Dir(r)}

	out, _, code := run(t, r, env, "hook", "git-root", filepath.Join(r, "p", "n"))
	if want := "0\n" + filepath.Join(r, "p") + "\n"; out != want || code != 0 {
		t.Errorf("nested = (%q, %d), want (%q, 0)", out, code, want)
	}
	out, _, _ = run(t, r, env, "hook", "git-root", filepath.Join(r, "p"))
	if want := "1\n" + filepath.Join(r, "p") + "\n"; out != want {
		t.Errorf("own root = %q, want %q", out, want)
	}
	mkdirs(t, filepath.Join(r, "x"))
	out, _, _ = run(t, r, env, "hook", "git-root", filepath.Join(r, "x"))
	if out != "0\n\n" {
		t.Errorf("no root = %q, want %q", out, "0\n\n")
	}
}

func TestCommandsUsage(t *testing.T) {
	for _, name := range []string{"abspath", "git-root", "wiring-state", "script-state"} {
		for _, args := range [][]string{{"hook", name}, {"hook", name, "a", "b"}} {
			out, errOut, code := run(t, "/w", nil, args...)
			if out != "" || code != cli.ExitUsage || !strings.Contains(errOut, "usage: rsdd hook "+name+" ") {
				t.Errorf("%v = (%q, %q, %d), want usage on stderr and exit 2", args, out, errOut, code)
			}
		}
	}
}

func TestHookGroupHelpListsTheCommands(t *testing.T) {
	out, _, code := run(t, "/w", nil, "hook", "--help")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, name := range []string{"abspath", "git-root", "wiring-state", "script-state"} {
		if !strings.Contains(out, name) {
			t.Errorf("hook --help does not list %s:\n%s", name, out)
		}
	}
}
