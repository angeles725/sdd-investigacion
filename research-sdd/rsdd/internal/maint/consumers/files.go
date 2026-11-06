package consumers

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// listing is the repository and the files it holds, sorted.
type listing struct {
	top   string
	files []string
}

// list asks git for the repository root and for tracked files plus untracked files that are not ignored.
// Without git, or outside a work tree, the answer is the degraded outcome (no count is printed); a listing that
// git accompanied with anything on stderr is degraded too, since the list may be incomplete.
func list(s cli.Stdio, repo string) (listing, *outcome) {
	env := s.Environment()
	if len(kitmaint.MissingDeps(env, s.Cwd, "git")) > 0 {
		return listing{}, degraded(stateNoGit)
	}
	dir := s.Cwd
	if repo != "" {
		dir = filepath.Clean(kitmaint.Abs(s.Cwd, repo))
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			return listing{}, &outcome{err: fmt.Sprintf(stateRepoNotDir, dir), rc: cli.ExitOperational}
		}
	}
	g := gitRunner(s)
	top, _, err := g.RunWithStderr(dir, "rev-parse", "--show-toplevel")
	code, bad := gitError(err, "rev-parse", dir)
	root := strings.TrimSuffix(string(top), "\n")
	if bad != nil {
		return listing{}, bad
	}
	if code != 0 || root == "" {
		return listing{}, degraded(fmt.Sprintf(stateNoWorkTree, dir))
	}
	ls, lsErr, err := g.RunWithStderr(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	code, bad = gitError(err, "ls-files", root)
	switch {
	case bad != nil:
		return listing{}, bad
	case code != 0:
		return listing{}, &outcome{err: fmt.Sprintf(stateListFailed, code, root), rc: cli.ExitOperational}
	case len(lsErr) > 0:
		return listing{}, stderrDegraded(lsErr)
	}
	return listing{top: root, files: splitNUL(string(ls))}, nil
}

// splitNUL is the sorted, de-duplicated names of a NUL-separated list (a path in a merge conflict is listed twice).
func splitNUL(raw string) []string {
	var out []string
	for _, f := range strings.Split(raw, "\x00") {
		if f != "" {
			out = append(out, f)
		}
	}
	sort.Strings(out)
	uniq := out[:0]
	for i, f := range out {
		if i == 0 || f != out[i-1] {
			uniq = append(uniq, f)
		}
	}
	return uniq
}
