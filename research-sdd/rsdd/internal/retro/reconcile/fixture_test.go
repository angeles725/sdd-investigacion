package reconcile

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// The repository fixture of the closure-evidence cases: a throwaway repo whose local ref origin/main holds
// fixMain, with fixSide on a side branch (HEAD) that origin/main does not reach. Author, committer and dates are
// pinned, so the object ids are the same on every machine and the recorded goldens can name them.
const (
	fixMain = "673acccbded2ca6631ff258308a13db8c7aaa2ea"
	fixSide = "c744f7bcb91095a4102d338c09a3138a93aef953"
)

func fixRunner(dir string) git.Runner {
	// gitfixture.Env turns off the detached maintenance a commit starts (kit issue #2624), so t.TempDir's cleanup
	// never races it.
	return git.Runner{Env: gitfixture.Env([]string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + dir, "LC_ALL=C",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		"GIT_AUTHOR_DATE=2026-01-01T00:00:00+0000", "GIT_COMMITTER_DATE=2026-01-01T00:00:00+0000",
	})}
}

// buildFixRepo creates the fixture in dir and returns the ids of its two commits.
func buildFixRepo(t *testing.T, dir string) (main, side string) {
	t.Helper()
	mustMkdir(t, dir)
	g := fixRunner(dir)
	steps := [][]string{
		{"init", "-q", "."}, {"commit", "-q", "--allow-empty", "-m", "main commit"},
		{"update-ref", "refs/remotes/origin/main", "HEAD"},
		{"checkout", "-q", "-b", "side"}, {"commit", "-q", "--allow-empty", "-m", "side commit"},
	}
	for _, s := range steps {
		if _, err := g.Run(dir, s...); err != nil {
			t.Fatalf("fixture step %v: %v", s, err)
		}
	}
	main, _, _ = g.ResolveCommit(dir, "origin/main")
	side, _, _ = g.ResolveCommit(dir, "HEAD")
	return main, side
}

func makeFixRepo(t *testing.T, dir string) {
	t.Helper()
	if main, side := buildFixRepo(t, dir); main != fixMain || side != fixSide {
		t.Fatalf("fixture object ids moved (git version?): main=%s side=%s", main, side)
	}
}

// makeShallowClone is a depth-1 clone of src: it holds the side commit only, so MAIN is "not fetched".
func makeShallowClone(t *testing.T, src, dst string) {
	t.Helper()
	root := filepath.Dir(dst)
	if _, err := fixRunner(root).Run(root, "clone", "-q", "--depth", "1", "--no-local", src, dst); err != nil {
		t.Fatalf("shallow clone: %v", err)
	}
}

// makeNoGitBin is a bin dir holding the tools the legacy script needs but no git, for the git-missing state.
func makeNoGitBin(t *testing.T, dir string) {
	t.Helper()
	mustMkdir(t, dir)
	for _, tool := range strings.Fields("awk gawk mawk grep sed cat sort tr paste find cut head basename dirname mktemp rm uniq env readlink wc date iconv tail xargs sh bash") {
		if p, err := exec.LookPath(tool); err == nil {
			_ = os.Symlink(p, filepath.Join(dir, tool))
		}
	}
}
