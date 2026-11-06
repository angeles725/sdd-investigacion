package consumers

import (
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// outcome is a run that ends before the report: what it prints and its exit code.
type outcome struct {
	out, err string
	rc       int
}

func (o outcome) emit(s cli.Stdio) int {
	io.WriteString(s.Out, o.out)
	io.WriteString(s.Err, o.err)
	return o.rc
}

func degraded(why string) *outcome {
	return &outcome{out: stateDegradedOut, err: why, rc: cli.ExitDegraded}
}

// listing is the repository and the files it holds, sorted.
type listing struct {
	top   string
	files []string
}

// list asks git for the repository root and for tracked files plus untracked files that are not ignored.
// Without git, or outside a work tree, the answer is the degraded outcome (no count is printed).
func list(s cli.Stdio, repo string) (listing, *outcome) {
	env := s.Environment()
	if len(kitmaint.MissingDeps(env, s.Cwd, "git")) > 0 {
		return listing{}, degraded(stateNoGit)
	}
	r := &kitmaint.Runner{Env: env, Cwd: s.Cwd, Now: s.Clock, Err: io.Discard, Getenv: s.Env}
	dir := s.Cwd
	if repo != "" {
		dir = filepath.Clean(kitmaint.Abs(s.Cwd, repo))
	}
	top := r.Git(dir, "rev-parse", "--show-toplevel")
	root := strings.TrimSuffix(top.Out, "\n")
	if top.RC != 0 || root == "" {
		return listing{}, degraded(fmt.Sprintf(stateNoWorkTree, dir))
	}
	ls := r.Git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	if ls.RC != 0 {
		return listing{}, &outcome{err: fmt.Sprintf(stateListFailed, ls.RC, root), rc: cli.ExitOperational}
	}
	return listing{top: root, files: splitNUL(ls.Out)}, nil
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
