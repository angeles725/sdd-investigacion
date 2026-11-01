//go:build !nodiff

package hook

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Differential test for `rsdd hook kit-run` against the FROZEN bash original (testdata/legacy/hook-kit-run.sh,
// a verbatim copy of templates/hook-kit-run.sh at the port commit): same fake kits, same environment, same
// stdin; stdout, stderr and the exit code must be byte-equal. Only a missing bash or jq skips, loudly.

const guardTemplate = "../../../templates/hook-pretool-pkill-guard.sh"

// envKeys are the variables the resolver reads (plus the stub's own knob). Everything else is the ambient process
// environment, inherited by the child exactly as `exec bash` inherits it.
var envKeys = []string{"HOME", "RESEARCH_SDD_KIT", "GENTLE_PI_AGENT_HOME", "PI_CODING_AGENT_DIR", "STUB_RC"}

type outcome struct {
	out, err string
	rc       int
}

type scenario struct {
	name  string
	setup func(t *testing.T, root string) (env map[string]string) // builds kits/home under root; returns the env
	args  func(root string) []string
	stdin string
}

func stubKit(t *testing.T, dir string) {
	t.Helper()
	for _, d := range []string{"toolbelt", "templates"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	probe := "#!/usr/bin/env bash\ncat\necho \"stub-ran:$(basename \"$0\"):$*\"\necho \"stub-err:$*\" >&2\nexit \"${STUB_RC:-0}\"\n"
	if err := os.WriteFile(filepath.Join(dir, "toolbelt", "probe.sh"), []byte(probe), 0o755); err != nil {
		t.Fatal(err)
	}
	g, err := os.ReadFile(guardTemplate)
	if err != nil {
		t.Fatalf("pkill guard template not found: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "templates", "hook-pretool-pkill-guard.sh"), g, 0o755); err != nil {
		t.Fatal(err)
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func scenarios() []scenario {
	const pk = `{"tool_name":"Bash","tool_input":{"command":"pkill -f foo"}}`
	const pg = `{"tool_input":{"command":"pgrep -f foo"}}`
	const ok = `{"tool_input":{"command":"ls -la"}}`
	probe := func(string) []string { return []string{"toolbelt/probe.sh", "a", "b c", ""} }
	guard := func(string) []string { return []string{"templates/hook-pretool-pkill-guard.sh"} }
	home := func(root string) map[string]string { return map[string]string{"HOME": filepath.Join(root, "home")} }
	withKit := func(root string) map[string]string {
		e := home(root)
		e["RESEARCH_SDD_KIT"] = filepath.Join(root, "kit")
		return e
	}
	return []scenario{
		{"env kit passes args stdin rc", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "kit"))
			e := withKit(r)
			e["STUB_RC"] = "7"
			return e
		}, probe, `{"x":1}`},
		{"env kit rc 0 no stdin", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) }, probe, ""},
		{"claude launcher with tilde", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "home", "kits", "k"))
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "x\nKit path: ~/kits/k\n")
			return home(r)
		}, probe, ""},
		{"pi launcher Kit checkout", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k-pi"))
			write(t, filepath.Join(r, "home", ".pi", "agent", "AGENTS.md"), "Kit checkout: "+filepath.Join(r, "k-pi")+"\n")
			return home(r)
		}, probe, ""},
		{"gentle-shell launcher", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k-gs"))
			write(t, filepath.Join(r, "home", ".gentle-shell", "agent", "AGENTS.md"), "Kit path: "+filepath.Join(r, "k-gs")+"\n")
			return home(r)
		}, probe, ""},
		{"GENTLE_PI_AGENT_HOME launcher", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k-gp"))
			write(t, filepath.Join(r, "gp", "AGENTS.md"), "Kit path: "+filepath.Join(r, "k-gp")+"\n")
			e := home(r)
			e["GENTLE_PI_AGENT_HOME"] = filepath.Join(r, "gp")
			return e
		}, probe, ""},
		{"PI_CODING_AGENT_DIR launcher", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k-pc"))
			write(t, filepath.Join(r, "pc", "AGENTS.md"), "Kit path: "+filepath.Join(r, "k-pc")+"\n")
			e := home(r)
			e["PI_CODING_AGENT_DIR"] = filepath.Join(r, "pc")
			return e
		}, probe, ""},
		{"default checkout", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "home", "investigacion", "sdd-investigacion", "research-sdd"))
			return home(r)
		}, probe, ""},
		{"env beats launcher", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "kit"))
			stubKit(t, filepath.Join(r, "k-file"))
			write(t, filepath.Join(r, "k-file", "toolbelt", "probe.sh"), "#!/usr/bin/env bash\necho from-file\n")
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "Kit path: "+filepath.Join(r, "k-file")+"\n")
			return withKit(r)
		}, probe, ""},
		{"backtick and padded launcher value", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "home", "kits", "k"))
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "Kit path:   `~/kits/k`  \t\n")
			return home(r)
		}, probe, ""},
		{"only the first launcher line is read", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k2"))
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "Kit path: /no/such\nKit path: "+filepath.Join(r, "k2")+"\n")
			return home(r)
		}, probe, ""},
		{"Kit checkout beats Kit path in one file", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "ka"))
			stubKit(t, filepath.Join(r, "kb"))
			write(t, filepath.Join(r, "kb", "toolbelt", "probe.sh"), "#!/usr/bin/env bash\necho kb\n")
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "Kit path: "+filepath.Join(r, "kb")+"\nKit checkout: "+filepath.Join(r, "ka")+"\n")
			return home(r)
		}, probe, ""},
		{"launcher is a directory, skipped", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "home", "investigacion", "sdd-investigacion", "research-sdd"))
			if err := os.MkdirAll(filepath.Join(r, "home", ".claude", "CLAUDE.md"), 0o755); err != nil {
				t.Fatal(err)
			}
			return home(r)
		}, probe, ""},
		{"invalid env falls through with a typed warning", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "k"))
			write(t, filepath.Join(r, "home", ".claude", "CLAUDE.md"), "Kit path: "+filepath.Join(r, "k")+"\n")
			e := home(r)
			e["RESEARCH_SDD_KIT"] = filepath.Join(r, "nope-kit")
			return e
		}, probe, ""},
		{"nothing resolves", func(t *testing.T, r string) map[string]string { return home(r) }, probe, ""},
		{"script missing in the kit", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"toolbelt/nope.sh"} }, ""},
		{"script is a directory", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"toolbelt"} }, ""},
		{"dotdot rel", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"../etc/x.sh"} }, ""},
		{"dotdot in the middle", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"toolbelt/../toolbelt/probe.sh"} }, ""},
		{"trailing dotdot", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"toolbelt/.."} }, ""},
		{"dots in a name are fine", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "kit"))
			write(t, filepath.Join(r, "kit", "toolbelt", "a..b.sh"), "#!/usr/bin/env bash\necho dots\n")
			return withKit(r)
		}, func(string) []string { return []string{"toolbelt/a..b.sh"} }, ""},
		{"absolute rel", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(r string) []string { return []string{filepath.Join(r, "kit", "toolbelt", "probe.sh")} }, ""},
		{"no script given", func(t *testing.T, r string) map[string]string { return withKit(r) }, func(string) []string { return nil }, ""},
		{"empty script given", func(t *testing.T, r string) map[string]string { return withKit(r) }, func(string) []string { return []string{""} }, ""},
		{"empty script given with the guard stdin", func(t *testing.T, r string) map[string]string { return withKit(r) }, func(string) []string { return []string{"", "x"} }, pk},
		// the pkill guard fails closed: ask for a pkill/pgrep payload, pass anything else
		{"guard unresolved + pkill", func(t *testing.T, r string) map[string]string { return home(r) }, guard, pk},
		{"guard unresolved + pgrep by suffix", func(t *testing.T, r string) map[string]string { return home(r) },
			func(string) []string { return []string{"research-sdd/templates/hook-pretool-pkill-guard.sh"} }, pg},
		{"guard unresolved + other command", func(t *testing.T, r string) map[string]string { return home(r) }, guard, ok},
		{"guard unresolved + empty stdin", func(t *testing.T, r string) map[string]string { return home(r) }, guard, ""},
		{"guard unresolved + garbage mentioning pkill", func(t *testing.T, r string) map[string]string { return home(r) }, guard, "{bad pkill"},
		{"guard unresolved + reason text is JSON-escaped", func(t *testing.T, r string) map[string]string { return home(r) },
			func(string) []string { return []string{"templates/hook-pretool-pkill-guard.sh"} }, "pgrep \"\x01 "},
		{"guard escaping rel + pkill", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"../templates/hook-pretool-pkill-guard.sh"} }, pk},
		{"guard script missing + pkill", func(t *testing.T, r string) map[string]string {
			stubKit(t, filepath.Join(r, "kit"))
			if err := os.Remove(filepath.Join(r, "kit", "templates", "hook-pretool-pkill-guard.sh")); err != nil {
				t.Fatal(err)
			}
			return withKit(r)
		}, guard, pk},
		{"guard resolved runs the real guard (deny)", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) }, guard, pk},
		{"guard resolved runs the real guard (allow)", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) }, guard, ok},
		{"guard resolved, strict flag passes through", func(t *testing.T, r string) map[string]string { stubKit(t, filepath.Join(r, "kit")); return withKit(r) },
			func(string) []string { return []string{"templates/hook-pretool-pkill-guard.sh", "--strict-name-kill"} }, `{"tool_name":"Bash","tool_input":{"command":"killall x"}}`},
	}
}

func runLegacy(t *testing.T, root string, env map[string]string, stdin string, args []string) outcome {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found; kit-run is NOT proven against the bash original in this run")
	}
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("differential: jq not found; kit-run is NOT proven against the bash original in this run")
	}
	script, err := filepath.Abs(filepath.Join("testdata", "legacy", "hook-kit-run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bash, append([]string{script}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C.utf8"}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Dir = root
	cmd.Stdin = strings.NewReader(stdin)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	rc := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("cannot run the legacy kit-run: %v", err)
		}
		rc = ee.ExitCode()
	}
	return outcome{so.String(), se.String(), rc}
}

// runGo runs the Go command with the same environment. The resolver reads Stdio.Env; the child inherits the
// process environment, so the same values are set on the test process (t.Setenv, hence no t.Parallel here).
func runGo(t *testing.T, env map[string]string, stdin string, args []string) outcome {
	t.Helper()
	for _, k := range envKeys {
		t.Setenv(k, env[k])
	}
	var o, e bytes.Buffer
	rc := KitRun(args, cli.Stdio{In: strings.NewReader(stdin), Out: &o, Err: &e, Env: os.Getenv})
	return outcome{o.String(), e.String(), rc}
}

func TestDifferentialKitRun(t *testing.T) {
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, "home"), 0o755); err != nil {
				t.Fatal(err)
			}
			env := sc.setup(t, root)
			args := sc.args(root)
			want := runLegacy(t, root, env, sc.stdin, args)
			got := runGo(t, env, sc.stdin, args)
			if got != want {
				t.Errorf("diverges from the bash original\n args: %q\n  got: rc=%d out=%q err=%q\n want: rc=%d out=%q err=%q",
					args, got.rc, got.out, got.err, want.rc, want.out, want.err)
			}
			if want.out == "" && want.err == "" && want.rc == 0 && sc.name != "guard unresolved + other command" &&
				sc.name != "guard unresolved + empty stdin" && sc.name != "guard resolved runs the real guard (allow)" {
				t.Errorf("scenario produced no observable output at all (silent zero?): %q", sc.name)
			}
		})
	}
}
