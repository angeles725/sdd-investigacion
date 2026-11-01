package budget

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// toolbelt/verify-session-budget.sh is now a compatibility shim over `rsdd budget verify`. These tests run the REAL shim with
// RSDD_BIN pointing at a binary built into a temp dir (never the kit's bin/: an unset RSDD_BIN would build there and break the
// kit-tree check), and hold its behavior to the frozen legacy script.

var (
	buildOnce sync.Once
	builtBin  string
	buildErr  error
)

// rsddBin builds cmd/rsdd once per test binary into a directory outside the worktree.
func rsddBin(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "budshim")
		if err != nil {
			buildErr = err
			return
		}
		builtBin = filepath.Join(dir, "rsdd")
		goBin, err := exec.LookPath("go")
		if err != nil {
			buildErr = err
			return
		}
		c := exec.Command(goBin, "build", "-o", builtBin, "./cmd/rsdd")
		c.Dir = abs(t, "../..")
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

func TestMain(m *testing.M) {
	code := m.Run()
	if builtBin != "" {
		_ = os.RemoveAll(filepath.Dir(builtBin))
	}
	os.Exit(code)
}

const realShimRel = "../../../toolbelt/verify-session-budget.sh"

func runShim(t *testing.T, script string, p prepared, bin string) result {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	c := exec.Command(bash, append([]string{script}, p.args...)...)
	c.Env = withEnv(p.env, "RSDD_BIN="+bin)
	c.Dir = p.root
	var out, errb strings.Builder
	c.Stdout, c.Stderr = &out, &errb
	code := codeOf(c.Run())
	return result{out.String(), errb.String(), code}
}

func TestShim_matchesLegacy(t *testing.T) {
	bin := rsddBin(t)
	for _, name := range []string{"empty", "absent", "badjson", "usage-noarg", "usage-badharness", "mixed", "degraded", "pi-card", "pi-both"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := caseByName(t, name)
			c.gate(t)
			p := c.prepare(t, "")
			// the shim takes the script's own arguments: no --toolbelt (it supplies its own directory)
			got := runShim(t, abs(t, realShimRel), p, bin)
			want := runLegacy(t, p.toolbelt, p.args, p.env, p.root)
			if norm(got, p.root) != norm(want, p.root) {
				t.Errorf("the shim differs from the frozen script\n--- script (exit %d)\n%s%s\n--- shim (exit %d)\n%s%s", want.code, want.out, want.err, got.code, got.out, got.err)
			}
		})
	}
}

// The shim finds lib/session-budget-pi.mjs from its OWN physical directory, also when it is reached through a symlink.
func TestShim_throughSymlink(t *testing.T) {
	needNode(t)
	needBwrap(t)
	bin := rsddBin(t)
	c := caseByName(t, "pi-card")
	p := c.prepare(t, "")
	link := filepath.Join(p.root, "linked-verify.sh")
	if err := os.Symlink(abs(t, realShimRel), link); err != nil {
		t.Fatal(err)
	}
	got := runShim(t, link, p, bin)
	want := runLegacy(t, p.toolbelt, p.args, p.env, p.root)
	if norm(got, p.root) != norm(want, p.root) {
		t.Errorf("through a symlink the shim differs from the script:\n%s%s\nvs\n%s%s", got.out, got.err, want.out, want.err)
	}
}

// With no usable rsdd the shim fails loudly (typed, exit 2), never with an empty success.
func TestShim_rsddUnavailable(t *testing.T) {
	c := caseByName(t, "empty")
	p := c.prepare(t, "")
	r := runShim(t, abs(t, realShimRel), p, filepath.Join(p.root, "no-such-rsdd"))
	if r.code != 2 || !strings.Contains(r.err, "degraded: rsdd-unavailable") || r.out != "" {
		t.Errorf("want exit 2 with a typed rsdd-unavailable line and no stdout, got exit %d stdout=%q stderr=%q", r.code, r.out, r.err)
	}
}
