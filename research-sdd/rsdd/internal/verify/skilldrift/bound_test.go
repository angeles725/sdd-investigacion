package skilldrift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// legacy H4o: a 0.7 s verify under a 1 s bound is never reported as timed out (10 runs). H4g/H4j/H4k: after a fast finish nothing
// is left running and nothing is signalled; the Go bound is a deadline on one process group, so there is no watchdog subshell to
// leak (H4p, H4q and H4r pinned the bash watchdog's sleep probing and have no Go counterpart).
func TestFastFinishIsNeverATimeoutAndLeavesNothing(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "stub")
	stub := filepath.Join(w.tb, "install-verify-stub.sh")
	write(t, stub, "#!/usr/bin/env bash\nsleep 0.7\necho \"verify harness=pi status=behind\"\n", 0o755)
	e := newEnvView(cli.Stdio{Environ: func() []string { return w.runEnv(nil) }})
	for i := 0; i < 10; i++ {
		r := runVerify(e, stub, w.root, 1)
		if r.timedOut || r.rc != 0 || !strings.Contains(r.out, "status=behind") {
			t.Fatalf("run %d: timedOut=%v rc=%d out=%q", i, r.timedOut, r.rc, r.out)
		}
	}
	if left := w.leftover(); len(left) != 0 {
		t.Errorf("temp entries left behind: %v", left)
	}
}

// legacy 5 / PIH2: the kit source skill exists, and each installed harness deploys under its own home-relative directory.
func TestKitSourceAndDeployedPaths(t *testing.T) {
	if _, err := os.Stat(filepath.Join(liveKit(t), "skills", "research-sdd", "SKILL.md")); err != nil {
		t.Fatalf("kit SKILL.md source missing: %v", err)
	}
	w := newWorld(t, "")
	bothInstalled(t, w)
	for _, rel := range []string{".pi/agent", ".gentle-shell"} {
		if _, err := os.Stat(filepath.Join(w.home, rel)); err != nil {
			t.Errorf("no deployment under <home>/%s: %v", rel, err)
		}
	}
}
