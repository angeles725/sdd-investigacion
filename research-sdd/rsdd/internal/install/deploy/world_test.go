//go:build unix && !nodiff

package deploy

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// world is one scenario's hermetic universe under a single scratch root:
//
//	home/  the HOME the installer targets (also passed as --home)   kit/   the staged kit with the frozen scripts
//	cwd/   the child's working directory                            tmp/   TMPDIR (mktemp lands here)
//	bin/   the only PATH: host tool symlinks + recording fakes       state/ the fake-call log
//
// Nothing outside root is reachable by the script except the read-only host tools linked into bin.
type world struct {
	t                                     *testing.T
	root, home, kit, cwd, tmp, bin, state string
	env                                   map[string]string
	kitBefore                             string
}

// result is one finished run, normalized for the scratch root.
type result struct {
	RC       int
	Out, Err string
	Calls    string // fake-tool calls recorded during the run
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root := t.TempDir()
	if p, err := filepath.EvalSymlinks(root); err == nil {
		root = p
	}
	w := &world{t: t, root: root}
	w.home, w.kit, w.cwd, w.tmp, w.bin, w.state = join(root, "home"), join(root, "kit"), join(root, "cwd"),
		join(root, "tmp"), join(root, "bin"), join(root, "state")
	for _, d := range []string{w.home, w.cwd, w.tmp, w.state} {
		mkdir(t, d)
	}
	buildPath(t, w.bin, join(w.state, "calls.log"))
	w.env = map[string]string{
		"PATH": w.bin, "HOME": w.home, "LC_ALL": "C", "TMPDIR": w.tmp,
		"XDG_CONFIG_HOME": join(root, "xdg", "config"), "XDG_CACHE_HOME": join(root, "xdg", "cache"),
		"XDG_DATA_HOME": join(root, "xdg", "data"), "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
		// the scratch root may sit inside a checkout: git must not discover it, and must not read host config
		"GIT_CEILING_DIRECTORIES": filepath.Dir(root), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
	}
	w.stageKit()
	w.kitBefore = w.snapshot(w.kit)
	return w
}

func join(p ...string) string { return filepath.Join(p...) }

func mkdir(t *testing.T, d string) {
	t.Helper()
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
}

// stageKit writes the synthetic kit, the real renderer and the FROZEN legacy scripts into kit/.
func (w *world) stageKit() {
	w.t.Helper()
	for rel, text := range kitFiles {
		w.put(join(w.kit, rel), []byte(text), 0o644)
	}
	for _, rel := range realKitFiles {
		b, err := os.ReadFile(kitroot.Path(w.t, filepath.FromSlash(rel)))
		if err != nil {
			w.t.Fatal(err)
		}
		w.put(join(w.kit, rel), b, 0o755)
	}
	for rel := range frozenLegacy {
		b, err := os.ReadFile(join(legacyDir, filepath.FromSlash(rel)))
		if err != nil {
			w.t.Fatal(err)
		}
		w.put(join(w.kit, rel), b, 0o755)
	}
}

func (w *world) put(abs string, b []byte, mode os.FileMode) {
	w.t.Helper()
	mkdir(w.t, filepath.Dir(abs))
	if err := os.WriteFile(abs, b, mode); err != nil {
		w.t.Fatal(err)
	}
}

// script is the staged frozen installer.
func (w *world) script() string { return join(w.kit, "install", "research-sdd-install.sh") }

// install runs the frozen installer with --home <scratch home> appended. The only runner that exists: a run
// without both HOME=<scratch> and --home <scratch> (or the explicit --home "" case) is refused.
func (w *world) install(args ...string) result { return w.runArgs(append(args, "--home", w.home)) }

// installNoHome runs with --home "" to pin the empty-value usage error; HOME is still the scratch home.
func (w *world) installEmptyHome(args ...string) result { return w.runArgs(append(args, "--home", "")) }

func (w *world) runArgs(args []string) result {
	w.t.Helper()
	ok := false
	for i, a := range args {
		if a == "--home" && i+1 < len(args) && (args[i+1] == w.home || args[i+1] == "") {
			ok = true
		}
	}
	if !ok {
		w.t.Fatalf("refusing to run the installer without --home <scratch>: %q", args)
	}
	if h, set := w.env["HOME"]; set && h != w.home {
		w.t.Fatalf("refusing to run with HOME=%q outside the scratch home", h)
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		needTool(w.t, "bash")
	}
	// umask is the one ambient setting an env list cannot pin: fix it so file modes are reproducible.
	c := exec.Command(bash, append([]string{"-c", `umask 022; exec bash "$@"`, "_", w.script()}, args...)...)
	c.Dir = w.cwd
	for k, v := range w.env {
		c.Env = append(c.Env, k+"="+v)
	}
	var o, e bytes.Buffer
	c.Stdout, c.Stderr = &o, &e
	rc := 0
	if err := c.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatalf("cannot run the installer: %v", err)
		}
		rc = ee.ExitCode()
	}
	r := result{RC: rc, Out: w.normalize(o.String()), Err: w.normalize(e.String())}
	r.Calls = w.drainCalls()
	w.assertContained(r)
	return r
}

// drainCalls reads and clears the fake-call log.
func (w *world) drainCalls() string {
	p := join(w.state, "calls.log")
	b, _ := os.ReadFile(p)
	_ = os.Remove(p)
	return strings.TrimSpace(w.normalize(string(b)))
}

// assertContained is the S4 check run after EVERY execution: no fake tool (network, package manager) was called,
// the staged kit and the frozen testdata are byte-identical to before, and the root holds only the known entries.
func (w *world) assertContained(r result) {
	w.t.Helper()
	if r.Calls != "" {
		w.t.Errorf("a forbidden tool was called: %s", r.Calls)
	}
	if got := w.snapshot(w.kit); got != w.kitBefore {
		w.t.Errorf("the installer changed the staged kit:\n%s", firstDiff(w.kitBefore, got))
	}
	TestFrozenLegacyScriptsAreByteIdentical(w.t)
	ents, err := os.ReadDir(w.root)
	if err != nil {
		w.t.Fatal(err)
	}
	for _, e := range ents {
		switch e.Name() {
		case "home", "kit", "cwd", "tmp", "bin", "state":
		default:
			w.t.Errorf("the installer created %s outside its scratch home", join(w.root, e.Name()))
		}
	}
}
