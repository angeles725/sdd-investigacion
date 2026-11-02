package budget

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Test harness. The differential tests run the FROZEN script (testdata/legacy) and the Go command from the same
// hand-built targets, with the same environment, and compare stdout, stderr and exit code. Hooks run in a real
// bubblewrap sandbox, so the sandbox cases need a usable unprivileged bwrap: without one they SKIP with a typed
// line, and FAIL under RSDD_REQUIRE_BWRAP=1 (CI). The pi cases need node with TypeScript type stripping
// (RSDD_REQUIRE_NODE_TS=1 turns the skip into a failure). A missing bash fails: a skipped oracle proves nothing.

const fixturesRel = "../../../toolbelt/tests/fixtures/verify-session-budget"

type observed struct {
	stdout, stderr string
	rc             int
}

var (
	capsOnce          sync.Once
	haveBwrap, haveTS bool
)

func caps() {
	capsOnce.Do(func() {
		if p, err := exec.LookPath("bwrap"); err == nil {
			haveBwrap = exec.Command(p, "--ro-bind", "/", "/", "true").Run() == nil
		}
		if p, err := exec.LookPath("node"); err == nil {
			out, _ := exec.Command(p, "-p", "String(process.features.typescript)").Output()
			s := strings.TrimSpace(string(out))
			haveTS = s != "" && s != "false" && s != "undefined"
		}
	})
}

func needBwrap(t *testing.T) {
	t.Helper()
	caps()
	if haveBwrap {
		return
	}
	if os.Getenv("RSDD_REQUIRE_BWRAP") == "1" {
		t.Fatal("RSDD_REQUIRE_BWRAP=1 but there is no usable unprivileged bwrap (sandbox cases would SKIP)")
	}
	t.Skip("no usable bwrap: sandbox-dependent case skipped, not passed")
}

func needNodeTS(t *testing.T) {
	t.Helper()
	needBwrap(t)
	needTS(t)
}

// needTS is for the pi cases that run node but no sandbox.
func needTS(t *testing.T) {
	t.Helper()
	caps()
	if haveTS {
		return
	}
	if os.Getenv("RSDD_REQUIRE_NODE_TS") == "1" {
		t.Fatal("RSDD_REQUIRE_NODE_TS=1 but this node has no built-in TypeScript type stripping (the pi cases were not executed)")
	}
	t.Skip("node has no built-in TypeScript type stripping: pi case skipped, not passed")
}

// sbx is one sandbox of a test: a copy of the fixtures, a kit directory holding the frozen script, a private
// TMPDIR and HOME, and the environment both implementations run with.
type sbx struct {
	t        *testing.T
	root     string
	fix      string // copy of the fixture targets
	kit      string // <root>/kit
	toolbelt string // <root>/kit/toolbelt: the frozen script and lib/ (a link to the real helper directory)
	script   string
	cwd      string
}

func newSbx(t *testing.T) *sbx {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Fatal("bash is required: the frozen script is the oracle")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sb := &sbx{t: t, root: root}
	sb.fix = filepath.Join(root, "fix")
	sb.kit = filepath.Join(root, "kit")
	sb.toolbelt = filepath.Join(sb.kit, "toolbelt")
	sb.cwd = filepath.Join(root, "cwd")
	for _, d := range []string{sb.toolbelt, sb.cwd, filepath.Join(root, "tmp"), filepath.Join(root, "home")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	legacy, err := os.ReadFile(filepath.Join("testdata", "legacy", "verify-session-budget.sh"))
	if err != nil {
		t.Fatal(err)
	}
	sb.script = filepath.Join(sb.toolbelt, "verify-session-budget.sh")
	if err := os.WriteFile(sb.script, legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	reallib, err := filepath.Abs("../../../toolbelt/lib")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(reallib, filepath.Join(sb.toolbelt, "lib")); err != nil {
		t.Fatal(err)
	}
	fixSrc, err := filepath.Abs(fixturesRel)
	if err != nil {
		t.Fatal(err)
	}
	sb.cp(fixSrc+"/.", sb.fix)
	return sb
}

// cp is `cp -a src dst` (dst created).
func (sb *sbx) cp(src, dst string) {
	sb.t.Helper()
	if err := os.MkdirAll(dst, 0o755); err != nil {
		sb.t.Fatal(err)
	}
	if out, err := exec.Command("cp", "-a", src, dst).CombinedOutput(); err != nil {
		sb.t.Fatalf("cp -a %s %s: %v: %s", src, dst, err, out)
	}
}

// environ is the environment of a run: the test's PATH, a private HOME and TMPDIR, then overrides (KEY=VALUE;
// a bare "-KEY" removes the key).
func (sb *sbx) environ(extra ...string) []string {
	env := map[string]string{
		"PATH":                     os.Getenv("PATH"),
		"HOME":                     filepath.Join(sb.root, "home"),
		"TMPDIR":                   filepath.Join(sb.root, "tmp"),
		"LANG":                     "C.UTF-8",
		"RSDD_BUDGET_HOOK_TIMEOUT": "10",
	}
	for _, kv := range extra {
		if k, ok := strings.CutPrefix(kv, "-"); ok && !strings.Contains(k, "=") {
			delete(env, k)
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		env[k] = v
	}
	var out []string
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	return out
}

func stdioFor(env []string, cwd string, out, errb *bytes.Buffer) cli.Stdio {
	get := func(k string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, k+"="); ok {
				v = s
			}
		}
		return v
	}
	return cli.Stdio{In: strings.NewReader(""), Out: out, Err: errb, Env: get, Environ: func() []string { return env }, Clock: nil, Cwd: cwd}
}

// legacy runs the frozen script.
func (sb *sbx) legacy(env []string, args ...string) observed {
	sb.t.Helper()
	cmd := exec.Command("bash", append([]string{sb.script}, args...)...)
	cmd.Dir, cmd.Env = sb.cwd, env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		sb.t.Fatalf("bash %v: %v", args, err)
	}
	return observed{out.String(), errb.String(), rc}
}

// golang runs the Go command the way the shim does: through the command table, with --toolbelt.
func (sb *sbx) golang(env []string, args ...string) observed {
	sb.t.Helper()
	var out, errb bytes.Buffer
	full := append([]string{"budget", "session", "--toolbelt", sb.toolbelt}, args...)
	rc := cli.Run(Commands, full, stdioFor(env, sb.cwd, &out, &errb))
	return observed{out.String(), errb.String(), rc}
}

var workDir = regexp.MustCompile(`tmp\.[A-Za-z0-9]+`)

// same runs both on the same arguments and environment and requires identical stdout, stderr and exit code.
func (sb *sbx) same(what string, env []string, args ...string) observed {
	sb.t.Helper()
	want := sb.legacy(env, args...)
	got := sb.golang(env, args...)
	if want != got {
		sb.t.Errorf("%s differs from the frozen script:\n--- legacy rc=%d stderr=%q\n%s\n--- go rc=%d stderr=%q\n%s", what, want.rc, want.stderr, want.stdout, got.rc, got.stderr, got.stdout)
	}
	return got
}

func (sb *sbx) target(name string) string { return filepath.Join(sb.fix, name) }

// mkTarget writes a target with .claude/settings.json and the given hook scripts (name -> body, executable).
func (sb *sbx) mkTarget(name, settings string, hooks map[string]string) string {
	sb.t.Helper()
	d := filepath.Join(sb.root, "targets", name)
	if err := os.MkdirAll(filepath.Join(d, ".claude", "hooks"), 0o755); err != nil {
		sb.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, ".claude", "settings.json"), []byte(settings), 0o644); err != nil {
		sb.t.Fatal(err)
	}
	for n, body := range hooks {
		if err := os.WriteFile(filepath.Join(d, ".claude", "hooks", n), []byte("#!/usr/bin/env bash\n"+body), 0o755); err != nil {
			sb.t.Fatal(err)
		}
	}
	return d
}

// mkbin builds a PATH directory holding links to the tools the script, the Go command and the stub hooks use,
// minus the omitted ones.
func (sb *sbx) mkbin(name string, omit ...string) string {
	sb.t.Helper()
	d := filepath.Join(sb.root, name)
	if err := os.MkdirAll(d, 0o755); err != nil {
		sb.t.Fatal(err)
	}
	skip := map[string]bool{}
	for _, o := range omit {
		skip[o] = true
	}
	for _, tool := range []string{"mktemp", "rm", "mkdir", "basename", "dirname", "head", "cut", "tr", "wc", "cat", "sleep", "timeout", "jq", "bwrap",
		"cp", "date", "true", "env", "bash", "od", "find", "sort", "ln", "node", "git", "seq", "printf", "touch"} {
		if skip[tool] {
			continue
		}
		if p, err := exec.LookPath(tool); err == nil {
			_ = os.Symlink(p, filepath.Join(d, tool))
		}
	}
	return d
}

// shim writes an executable script into dir.
func (sb *sbx) shim(dir, name, body string) {
	sb.t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		sb.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o755); err != nil {
		sb.t.Fatal(err)
	}
}

// runNoToolbelt dispatches the command without the shim's --toolbelt flag.
func runNoToolbelt(env []string, cwd string, args ...string) (stdout, stderr string, rc int) {
	var out, errb bytes.Buffer
	rc = cli.Run(Commands, append([]string{"budget", "session"}, args...), stdioFor(env, cwd, &out, &errb))
	return out.String(), errb.String(), rc
}

// runCLI dispatches through the table with an empty environment.
func runCLI(args []string, out, errb *bytes.Buffer) int {
	return cli.Run(Commands, args, stdioFor(nil, "/", out, errb))
}

func lines(s string) []string { return strings.Split(strings.TrimRight(s, "\n"), "\n") }

// has reports whether any line of s matches re.
func has(s, re string) bool { return regexp.MustCompile("(?m)" + re).MatchString(s) }

var sweepHooks = []string{"sweep-retros-hook", "sweep-audits-hook", "sweep-breakthroughs-hook", "verify-registry-hook",
	"verify-kit-clean-hook", "sweep-tools-hook", "verify-tool-catalog-hook", "verify-skill-drift-hook"}

// piEnv returns the environment of a pi run: the stub kit, the real kit extension, a 20 s cap.
func (sb *sbx) piEnv(extra ...string) []string {
	kit := filepath.Join(sb.root, "stubkit")
	for _, h := range sweepHooks {
		sb.shim(filepath.Join(kit, "toolbelt"), h+".sh",
			"#!/usr/bin/env bash\nprintf '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"%s\"}}' \"$(sleep \"${RSDD_STUB_SLEEP:-0}\"; head -c \"${RSDD_STUB_N:-100}\" /dev/zero | tr \"\\0\" k)\"\n")
	}
	real, err := filepath.Abs("../../../install/pi/research-sdd-hooks.ts")
	if err != nil {
		sb.t.Fatal(err)
	}
	if _, err := os.Stat(real); err != nil {
		sb.t.Fatalf("the real kit extension is required: %v", err)
	}
	return sb.environ(append([]string{"RSDD_BUDGET_KIT=" + kit, "RSDD_BUDGET_PI_HOOKS=" + real, "RSDD_BUDGET_HOOK_TIMEOUT=20", "RSDD_STUB_N=100"}, extra...)...)
}
