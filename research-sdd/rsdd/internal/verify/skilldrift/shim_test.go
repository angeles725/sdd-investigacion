package skilldrift

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// toolbelt/verify-skill-drift.sh and verify-skill-drift-hook.sh are compatibility shims over the Go commands. These tests run
// the REAL shims with RSDD_BIN pointing at a binary built into a temp dir (never the kit's bin/: an unset RSDD_BIN would build
// there), and hold them to the frozen legacy scripts.

var (
	buildOnce sync.Once
	builtBin  string
	buildErr  error
)

func rsddBin(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "skdshim")
		if err != nil {
			buildErr = err
			return
		}
		builtBin = filepath.Join(dir, "rsdd")
		c := exec.Command("go", "build", "-o", builtBin, "./cmd/rsdd")
		c.Dir = absPath(t, "../../..")
		if out, err := c.CombinedOutput(); err != nil {
			buildErr = &buildFailure{err, string(out)}
		}
	})
	if buildErr != nil {
		t.Fatalf("cannot build rsdd for the shim test: %v", buildErr)
	}
	return builtBin
}

type buildFailure struct {
	err error
	out string
}

func (b *buildFailure) Error() string { return b.err.Error() + ": " + b.out }

func (w *world) runShim(script, bin string, args, env []string) result {
	w.t.Helper()
	live := filepath.Join(liveKit(w.t), "toolbelt", script)
	return w.runExec(live, append(env, "RSDD_BIN="+bin), args)
}

func (w *world) runExec(path string, env, args []string) result {
	w.t.Helper()
	c := exec.Command("bash", append([]string{path}, w.subAll(args)...)...)
	c.Env, c.Dir = env, w.root
	var out, errb strings.Builder
	c.Stdout, c.Stderr = &out, &errb
	code := codeOf(c.Run()) // run first: operands are evaluated left to right
	return result{out.String(), errb.String(), code}
}

// legacy 1-4: both entry points exist, are executable and are the shims.
func TestShimsExistAndAreExecutable(t *testing.T) {
	for _, n := range []string{"verify-skill-drift.sh", "verify-skill-drift-hook.sh"} {
		p := filepath.Join(liveKit(t), "toolbelt", n)
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode()&0o111 == 0 {
			t.Errorf("%s is not executable", n)
		}
		if !strings.Contains(readFile(t, p), "rsdd_exec") || !strings.Contains(readFile(t, p), "RSDD_TOOLBELT_DIR") {
			t.Errorf("%s is not a shim over rsdd", n)
		}
	}
}

func TestDriftShimMatchesTheLegacyScript(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	bin := rsddBin(t)
	for _, c := range driftCases {
		switch c.name {
		case "single-insync", "single-diverged", "all-middle-diverged", "all-all-absent", "help", "single-unknown-harness", "single-home-unset", "profile-pi-insync", "all-last-diverged":
		default:
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			w := c.setupWorld(t)
			env := w.runEnv(c.env)
			want := w.norm(w.runBash("verify-skill-drift.sh", c.args, env))
			// the shim runs from the live toolbelt, whose kit is the live checkout: the real-kit variant has the same kit
			got := w.norm(w.runShim("verify-skill-drift.sh", bin, c.args, env))
			if got != want {
				t.Errorf("shim differs from the legacy script\n--- legacy (exit %d)\nstdout: %q\nstderr: %q\n--- shim (exit %d)\nstdout: %q\nstderr: %q",
					want.code, want.out, want.err, got.code, got.out, got.err)
			}
			if left := w.leftover(); len(left) != 0 {
				t.Errorf("temp entries left behind: %v", left)
			}
		})
	}
}

// Intended divergence 1, end to end: the absent report keeps its code 3 and gains the cli's degraded line.
func TestDriftShimAbsentKeepsExit3(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "")
	emptyClaudeRoot(t, w)
	r := w.runShim("verify-skill-drift.sh", rsddBin(t), []string{"--harness", "claude", "--home", "@HOME@"}, w.runEnv(nil))
	if r.code != 3 || !strings.Contains(r.err, "verify-skill-drift: absent harness=claude deployed=") {
		t.Errorf("exit %d stderr %q", r.code, r.err)
	}
}

func TestHookShimMatchesTheLegacyHook(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	needTool(t, "jq", "RSDD_REQUIRE_JQ")
	bin := rsddBin(t)
	for _, c := range hookCases {
		switch c.name {
		case "real-insync", "real-diverged", "real-all-diverged", "real-absent":
		default:
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			w, env := c.prepare(t)
			want := w.norm(w.runBashHook(env))
			got := w.norm(w.runShim("verify-skill-drift-hook.sh", bin, nil, env))
			if got != want {
				t.Errorf("shim differs\n--- legacy %+v\n--- shim %+v", want, got)
			}
		})
	}
}

// legacy SYMLINK-TOOLBELT: invoked through the persisted render dir, whose toolbelt/ is a symlink into the kit, the shim must
// still resolve the real kit root (kit issue #1024 round 4): re-rendering the render's own marker-free sources fails with
// "zero slot markers" otherwise.
func TestDriftShimThroughSymlinkedToolbelt(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	bin := rsddBin(t)
	w := newWorld(t, "")
	piInstalled(t, w)
	viaRender := filepath.Join(w.home, ".pi/agent/research-sdd/profile/general/toolbelt/verify-skill-drift.sh")
	if _, err := os.Stat(viaRender); err != nil {
		t.Fatalf("the render dir does not link the toolbelt: %v", err)
	}
	for _, args := range [][]string{{"--harness", "pi", "--home", "@HOME@"}, {"--all", "--home", "@HOME@"}} {
		r := w.runExec(viaRender, append(w.runEnv(nil), "RSDD_BIN="+bin), args)
		if r.code != 0 || strings.Contains(strings.ToLower(r.out+r.err), "zero slot markers") {
			t.Errorf("%v: exit %d out %q err %q", args, r.code, r.out, r.err)
		}
	}
}

// The shims announce a missing library instead of going silent.
func TestShimsAnnounceAMissingLib(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "")
	for _, n := range []string{"verify-skill-drift.sh", "verify-skill-drift-hook.sh"} {
		dir := filepath.Join(w.root, "bare-"+n)
		p := filepath.Join(dir, n)
		copyFile(t, filepath.Join(liveKit(t), "toolbelt", n), p, 0o755)
		r := w.runExec(p, w.runEnv(nil), nil)
		if n == "verify-skill-drift.sh" {
			if r.code != 2 || !strings.Contains(r.err, "degraded: rsdd-unavailable — rsdd-exec.sh missing beside") {
				t.Errorf("%s: exit %d stderr %q", n, r.code, r.err)
			}
			continue
		}
		if r.code != 0 || !strings.HasPrefix(r.out, "Research-SDD hook: lib/rsdd-exec.sh missing beside ") {
			t.Errorf("%s: exit %d stdout %q", n, r.code, r.out)
		}
	}
}
