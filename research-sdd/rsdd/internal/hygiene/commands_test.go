package hygiene

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

func TestTheDomainRegistersOneCommand(t *testing.T) {
	if len(Commands) != 1 {
		t.Fatalf("%d commands", len(Commands))
	}
	c := Commands[0]
	if c.Group != "hygiene" || c.Name != "clean-check" || c.Run == nil || c.Summary == "" || !c.PlainExit3 {
		t.Errorf("%+v", c)
	}
	if err := cli.Validate(Commands); err != nil {
		t.Error(err)
	}
}

// Exit 3 of a degraded scan prints the script's own typed lines: the process boundary adds no generic DEGRADED: line
// (PlainExit3), so the output is the script's byte for byte.
func TestDegradedScanAddsNoGenericLine(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	real, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	execfile.Write(t, root+"/bin/git", "#!/bin/sh\ncase \" $* \" in *' worktree list '*) echo boom >&2; exit 128;; esac\nexec "+real+" \"$@\"\n")
	for _, d := range []string{"repo", "tmp", "home"} {
		if err := os.MkdirAll(root+"/"+d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := []string{"PATH=" + root + "/bin:" + os.Getenv("PATH"), "HOME=" + root + "/home", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null"}
	for _, a := range [][]string{{"init", "-q", "-b", "main"}, {"-c", "user.name=t", "-c", "user.email=t@e.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "i"}} {
		c := exec.Command("git", append([]string{"-C", root + "/repo"}, a...)...)
		c.Env = env
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
	}
	var out, errw bytes.Buffer
	rc := cli.Run(Commands, []string{"hygiene", "clean-check", "--target", root + "/repo", "--tmp", root + "/tmp"},
		cli.Stdio{Out: &out, Err: &errw, Env: func(string) string { return "" }, Environ: func() []string { return env }, Clock: time.Now, Cwd: root})
	if rc != 3 || errw.String() != "" || !strings.Contains(out.String(), "DEGRADED-WORKTREE-SCAN git worktree list failed: boom\n") || !strings.Contains(out.String(), "CLEAN-CHECK: degraded (") {
		t.Errorf("rc %d\nout %q\nerr %q", rc, out.String(), errw.String())
	}
}
