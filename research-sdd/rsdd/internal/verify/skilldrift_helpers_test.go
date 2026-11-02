//go:build unix

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// sdWorld is one skill-drift test's world: a mini kit (install/adapters.sh frozen from the oracle, a kit
// SKILL.md), a home to deploy into and a fixed environment. The same world runs the Go command in process and
// the frozen bash scripts, so a differential compares like with like.
type sdWorld struct {
	t    *testing.T
	root string // scratch root: kit/ and home/ live under it
	kit  string
	home string
	env  map[string]string
}

const sdKitSkill = "# research-sdd skill\nkit source v1\n"

// sdLiveKit is the real kit root (the checkout this test runs in), for the files the world borrows unmodified.
func sdLiveKit(t *testing.T) string {
	t.Helper()
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// .../research-sdd/rsdd/internal/verify/<file> -> .../research-sdd
	return filepath.Clean(filepath.Join(filepath.Dir(here), "..", "..", ".."))
}

func sdTools(t *testing.T) string {
	t.Helper()
	dirs := map[string]bool{}
	var path []string
	for _, tool := range []string{"bash", "jq", "cat", "cmp", "sed", "awk", "grep", "cut", "tr", "head", "mktemp", "rm", "dirname", "basename", "readlink", "stat", "date", "env", "git", "timeout", "sleep"} {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Fatalf("%s is required (a skipped differential proves nothing): %v", tool, err)
		}
		if d := filepath.Dir(p); !dirs[d] {
			dirs[d] = true
			path = append(path, d)
		}
	}
	return strings.Join(path, ":")
}

func newSDWorld(t *testing.T) *sdWorld {
	t.Helper()
	root := t.TempDir()
	if p, err := filepath.EvalSymlinks(root); err == nil {
		root = p
	}
	w := &sdWorld{t: t, root: root, kit: filepath.Join(root, "kit"), home: filepath.Join(root, "home")}
	w.env = map[string]string{
		"PATH": sdTools(t), "HOME": w.home, "LC_ALL": "C", "TMPDIR": filepath.Join(root, "tmp"),
		"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
		// the scratch root may sit inside a checkout (GOTMPDIR does): git must not discover it
		"GIT_CEILING_DIRECTORIES":      filepath.Dir(root),
		"RESEARCH_SDD_KIT_STALE_CHECK": "off",
		// pi and gentle-shell default to the "general" profile, which is re-rendered; the world compares every
		// harness against the kit source unless a test deletes this.
		"RESEARCH_SDD_PROFILE": "claude",
	}
	for _, d := range []string{w.home, w.env["TMPDIR"], filepath.Join(w.kit, "toolbelt"), filepath.Join(w.kit, "skills", "research-sdd")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w.copy(filepath.Join("testdata", "legacy", "skilldrift", "adapters.sh"), "install/adapters.sh", 0o644)
	w.write("skills/research-sdd/SKILL.md", sdKitSkill)
	return w
}

// write puts text at kit-relative rel.
func (w *sdWorld) write(rel, text string) string {
	return w.put(filepath.Join(w.kit, rel), text, 0o644)
}

func (w *sdWorld) put(abs, text string, mode os.FileMode) string {
	w.t.Helper()
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(text), mode); err != nil {
		w.t.Fatal(err)
	}
	return abs
}

// copy puts the file at src (relative to this package) at kit-relative rel.
func (w *sdWorld) copy(src, rel string, mode os.FileMode) {
	w.t.Helper()
	b, err := os.ReadFile(src)
	if err != nil {
		w.t.Fatal(err)
	}
	w.put(filepath.Join(w.kit, rel), string(b), mode)
}

// liveCopy copies a file of the real kit (relative to the kit root) into the mini kit.
func (w *sdWorld) liveCopy(rel string, mode os.FileMode) {
	w.t.Helper()
	w.copy(filepath.Join(sdLiveKit(w.t), rel), rel, mode)
}

// withProfiles adds what render-profile.sh needs to render the "general" profile: the real renderer, the real
// profile and the real doctrine sources, with the skill source replaced by the real one so the render works.
func (w *sdWorld) withProfiles() {
	w.t.Helper()
	w.liveCopy("toolbelt/render-profile.sh", 0o755)
	w.liveCopy("profiles/general.slots.md", 0o644)
	for _, rel := range []string{"skills/research-sdd/SKILL.md", "PROMPT-LOOP.md", "METHODOLOGY.md"} {
		w.liveCopy(rel, 0o644)
	}
}

// withBash stages the frozen bash scripts beside the Go world, for the differential.
func (w *sdWorld) withBash() {
	w.t.Helper()
	w.copy(filepath.Join("testdata", "legacy", "skilldrift", "verify-skill-drift.sh"), "toolbelt/verify-skill-drift.sh", 0o755)
	w.copy(filepath.Join("testdata", "legacy", "skilldrift", "verify-skill-drift-hook.sh"), "toolbelt/verify-skill-drift-hook.sh", 0o755)
	w.copy(filepath.Join("testdata", "legacy", "lib", "hook-emit.sh"), "toolbelt/lib/hook-emit.sh", 0o644)
}

// deploy writes the harness's deployed SKILL.md under the world's home (relative config root crel).
func (w *sdWorld) deploy(crel, text string) string {
	return w.put(filepath.Join(w.home, crel, "skills", "research-sdd", "SKILL.md"), text, 0o644)
}

func (w *sdWorld) environ() []string {
	var e []string
	for k, v := range w.env {
		e = append(e, k+"="+v)
	}
	sort.Strings(e)
	return e
}

func (w *sdWorld) stdio(out, errb *bytes.Buffer) cli.Stdio {
	return cli.Stdio{
		In: strings.NewReader(""), Out: out, Err: errb,
		Env:     func(k string) string { return w.env[k] },
		Environ: w.environ,
		Clock:   time.Now,
		Cwd:     w.root,
	}
}

// runGo runs `rsdd verify skill-drift --kit <kit> args...` through the dispatcher, as the binary does.
func (w *sdWorld) runGo(args ...string) (stdout, stderr string, rc int) {
	return w.runGoKit(w.kit, args...)
}

// runGoKit is runGo with the kit root given (a symlinked path, say).
func (w *sdWorld) runGoKit(kit string, args ...string) (stdout, stderr string, rc int) {
	var out, errb bytes.Buffer
	rc = cli.Run(Commands, append([]string{"verify", "skill-drift", "--kit", kit}, args...), w.stdio(&out, &errb))
	return out.String(), errb.String(), rc
}

// runGoHook runs `rsdd verify skill-drift --hook <kit>/toolbelt`.
func (w *sdWorld) runGoHook() (stdout, stderr string, rc int) {
	var out, errb bytes.Buffer
	rc = cli.Run(Commands, []string{"verify", "skill-drift", "--hook", filepath.Join(w.kit, "toolbelt")}, w.stdio(&out, &errb))
	return out.String(), errb.String(), rc
}

// runBash runs the staged frozen script (script is "verify-skill-drift.sh" or the hook) with the world's env.
func (w *sdWorld) runBash(script string, args ...string) (stdout, stderr string, rc int) {
	return w.runBashAt(filepath.Join(w.kit, "toolbelt", script), args...)
}

// runBashAt runs the frozen script at an explicit path (a symlinked one, say).
func (w *sdWorld) runBashAt(path string, args ...string) (stdout, stderr string, rc int) {
	w.t.Helper()
	var out, errb bytes.Buffer
	cmd := exec.Command("bash", append([]string{path}, args...)...)
	cmd.Env = w.environ()
	cmd.Dir = w.root
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	switch e := err.(type) {
	case nil:
	case *exec.ExitError:
		rc = e.ExitCode()
	default:
		w.t.Fatalf("bash %s: %v", path, err)
	}
	return out.String(), errb.String(), rc
}

// scrub replaces the world's volatile paths so outputs of two runs compare equal.
func (w *sdWorld) scrub(s string) string {
	return reRenderTmp.ReplaceAllString(strings.NewReplacer(w.root, "<ROOT>").Replace(s), "tmp.X")
}

// reRenderTmp is a mktemp -d name; the Go and the bash runs each draw their own.
var reRenderTmp = regexp.MustCompile(`tmp\.[A-Za-z0-9]{6,}`)
