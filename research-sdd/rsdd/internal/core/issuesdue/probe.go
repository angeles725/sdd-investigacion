package issuesdue

import (
	"fmt"
	"os"
	"strings"
)

// Query is one cached probe: `rsdd retro reconcile [--toolbelt Toolbelt] --issues-cache Cache Retro`, answered in
// process. Every field but Toolbelt is required.
type Query struct {
	// Retro is the retro as the command line carries it (relative paths resolve against Cwd).
	Retro string
	// Cache is the --issues-cache file: the open issue bodies.
	Cache string
	// Toolbelt is the --toolbelt directory; "" resolves the kit as the command does.
	Toolbelt string
	// Cwd is the working directory of the command; Env reads its environment (RESEARCH_HOME, HOME,
	// RECONCILE_ISSUES_LIST_LIMIT, RESEARCH_SDD_KIT).
	Cwd string
	Env func(string) string
}

// Result is the verdict of a probe. Exactly one of the three shapes holds: Failure != "" (could not look),
// OutOfScope != "" (looked, classified nothing), or neither (classified: Untracked is the verdict, possibly empty).
type Result struct {
	// Untracked are the open rows no open issue tracks, in row order.
	Untracked []string
	// Failure is the whole stderr of a command that exits 1 (a degraded or absent-input stop), without its final newline.
	Failure string
	// OutOfScope is the "out-of-scope-marker: ..." line of a retro whose marker sits outside the leading block.
	OutOfScope string
}

// Probe answers what `rsdd retro reconcile --issues-cache F <retro>` reports for the open rows, without starting it:
// the same steps in the same order, so the same stop and the same text. It never queries gh and never reads the
// closed issues: with a cache and no --closed-cache the command does not either (it only notes that it skipped them).
func Probe(q Query) Result {
	var notes []string
	var oos string
	var stopped bool // a degraded line was given: the audit could not reach a verdict
	add := func(format string, args ...any) { notes = append(notes, fmt.Sprintf(format, args...)) }
	sink := Sink{Note: add, Fail: add, Degrade: func(format string, args ...any) { stopped = true; add(format, args...) }, OutOfScope: func(line string) { oos = line; add("%s", line) }}
	failed := func() Result { return Result{Failure: strings.Join(notes, "\n")} }

	kitRoot, ok := KitRoot(q.Cwd, q.Env, q.Toolbelt, add)
	if !ok {
		return failed()
	}
	if _, _, bad := ListLimit(q.Env); bad != "" {
		add("%s", bad)
		return failed()
	}
	path, target, ok := ResolveTarget(kitRoot, q.Cwd, q.Retro, q.Env, sink)
	if !ok {
		return failed()
	}
	// Read stops on a degraded line (could not look), a marker out of scope or a retro with no delta row (looked).
	ret, ok := Read(path, target, sink)
	switch {
	case !ok && stopped:
		return failed()
	case !ok:
		return Result{OutOfScope: oos}
	}
	bodies, err := os.ReadFile(q.Cache)
	if err != nil {
		sink.Degrade("degraded: --issues-cache file not readable: %s", q.Cache)
		return failed()
	}
	return Result{Untracked: ret.Untracked(IssueRowIDs(Normalize(string(bodies)), ret.Prefixes()))}
}
