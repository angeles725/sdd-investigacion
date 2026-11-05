package flakehunt

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// snapshot is everything observable of one scenario run: the streams, the exit code and every file the run left
// below the world root (output directories, recordings of the stubs, the repository listing), root-normalised.
type snapshot struct {
	Out   string            `json:"out"`
	Err   string            `json:"err"`
	RC    int               `json:"rc"`
	Files map[string]string `json:"files"`
}

// stamp is the default output directory name: a timestamp and the process id.
var stamp = regexp.MustCompile(`\d{8}T\d{6}-\d+`)

func (w *world) norm(s string) string {
	return stamp.ReplaceAllString(strings.ReplaceAll(s, w.root, "<W>"), "<TS>")
}

// build creates the world of a scenario and returns it with the full argument list (placeholders expanded) and the
// directory to run in.
func (sc scenario) build(t *testing.T) (*world, []string, string) {
	t.Helper()
	w := newWorld(t)
	if sc.setup != nil {
		sc.setup(w)
	}
	for _, e := range sc.env {
		w.env = append(w.env, w.expand(e))
	}
	args := sc.args
	if !sc.raw {
		args = append([]string{"--repo", "@R@", "--out", "@O@"}, args...)
	}
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = w.expand(a)
	}
	cwd := w.cwd
	if sc.cwd == "R" {
		cwd = w.repo
	}
	return w, out, cwd
}

// snap records the world after a run.
func (w *world) snap(r ran) snapshot {
	w.t.Helper()
	s := snapshot{Out: w.norm(r.out), Err: w.norm(r.err), RC: r.rc, Files: map[string]string{}}
	var repoTree []string
	err := filepath.WalkDir(w.root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(w.root, p)
		switch {
		case p == w.root:
			return nil
		case rel == "bin":
			return fs.SkipDir
		case rel == "repo" || strings.HasPrefix(rel, "repo/"):
			repoTree = append(repoTree, rel)
			return nil
		case d.Type()&fs.ModeSymlink != 0:
			s.Files[w.norm(rel)] = "-> symlink"
		case d.IsDir():
			s.Files[w.norm(rel)] = "dir"
		default:
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			s.Files[w.norm(rel)] = w.norm(string(b))
		}
		return nil
	})
	if err != nil {
		w.t.Fatal(err)
	}
	sort.Strings(repoTree)
	s.Files["<repo-tree>"] = strings.Join(repoTree, "\n")
	return s
}

func filesDiff(a, b map[string]string) string {
	var sb strings.Builder
	seen := map[string]bool{}
	for k, v := range a {
		seen[k] = true
		if w, ok := b[k]; !ok {
			sb.WriteString("only in legacy: " + k + "\n")
		} else if v != w {
			sb.WriteString("differs: " + k + "\n--- legacy\n" + v + "\n--- go\n" + w + "\n")
		}
	}
	for k := range b {
		if !seen[k] {
			sb.WriteString("only in go: " + k + "\n")
		}
	}
	return sb.String()
}
