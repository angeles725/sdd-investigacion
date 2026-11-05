package waitmerge

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// result is one run: stdout, stderr and the exit code.
type result struct {
	out, err string
	rc       int
}

// mergeGateEnv is the KIT_MERGE_GATE of a case: the recording shim under the name merge-gate.sh, as the bash suite
// does, so the call log names every merge-gate call.
func mergeGateEnv(t *testing.T, w *kitworld.World) string {
	t.Helper()
	p := filepath.Join(w.Dir, "merge-gate.sh")
	if err := os.Symlink(filepath.Join(w.Fix, "shim.sh"), p); err != nil && !os.IsExist(err) {
		t.Fatal(err)
	}
	return "KIT_MERGE_GATE=" + p
}

// goRun runs the command in w (cwd = its worktree) with the merge gate shim, and self as the rsdd binary.
func goRun(t *testing.T, w *kitworld.World, args []string, extra ...string) result {
	t.Helper()
	extra = append([]string{mergeGateEnv(t, w)}, extra...)
	return goRunIn(w, w.Wt, args, "", extra...)
}

func goRunIn(w *kitworld.World, cwd string, args []string, self string, extra ...string) result {
	s, o, e := w.Stdio(cwd, extra...)
	rc := run(args, s, deps{sleep: func(time.Duration) {}, self: self})
	return result{o.String(), e.String(), rc}
}

// happy scripts the all-green case; a case's own rules must come first (the first matching rule wins).
func happy(w *kitworld.World) {
	w.Rule("gh", "pr checks*", 0, "pr-checks-pass.txt", 0, "")
	w.Rule("gh", "pr view*", 0, "pr-state-merged.txt", 0, "")
	w.Rule("merge-gate.sh", "*", 0, "merge-gate-merged.txt", 0, "")
}

var degradedLine = regexp.MustCompile(`(?m)^DEGRADED: .*\n?`)

func count(calls, prefix string) int {
	n := 0
	for _, l := range strings.Split(calls, "\n") {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}
