package gate

import (
	"os"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// result is one run: stdout, stderr and the exit code.
type result struct {
	out, err string
	rc       int
}

// goRun runs the command in w (cwd = its worktree) with no signal source.
func goRun(w *kitworld.World, args []string, extra ...string) result {
	s, o, e := w.Stdio(w.Wt, extra...)
	rc := run(args, s, deps{sleep: time.Sleep})
	return result{o.String(), e.String(), rc}
}

// headRule makes `git rev-parse --short HEAD` answer abc1234 like the bash suite's head.txt fixture, and lets the
// bash tool's flock call pass (only the bash called it; Go locks in process).
func headRule(w *kitworld.World) {
	w.Rule("git", "*rev-parse --short HEAD", 0, "head.txt", 0, "")
	w.Rule("flock", "*", 0, "", 0, "")
}

// runAll puts a stub tests/run-all.sh into the worktree that records its arguments in the shim call log.
func runAll(t *testing.T, w *kitworld.World) {
	t.Helper()
	d := w.Wt + "/research-sdd/toolbelt/tests"
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	body := "#!/usr/bin/env bash\necho \"RUNALL $*\" >> \"$SHIM_STATE/calls.log\"\n"
	if err := os.WriteFile(d+"/run-all.sh", []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
