package secretscan

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// A scase is one black-box scenario: a fixture corpus built on disk, one scan mode and its inputs. The same case runs
// through the Go engine (golden replay, nodiff-visible) and through the frozen legacy script (differential,
// !nodiff). Mode "" scans a working-tree walk, "ff" a --files-from list, "committed" the history.
type scase struct {
	name   string
	build  func(w *world)
	mode   string
	target string   // the target as the caller writes it, relative to the scratch directory ("" = corpus)
	list   []string // ff: the entries, relative to the physical target (made absolute); "!" prefix = verbatim
	// ff: rawList replaces the list bytes; listFile "absent" points at a missing list, "dir" at a directory;
	// stdin feeds the list on stdin ("-").
	rawList  *string
	listFile string
	stdin    bool
	env      []string
	noGit    bool // PATH without git
	// unordered: the legacy report order of a multi-file walk is directory order; compare the lines as a set.
	unordered bool
	skipRoot  bool // needs a non-root user (permission bits)
	intended  []intended
}

type intended struct{ field, reason string }

type obs struct {
	stdout, stderr string
	exit           int
}

// world is one case materialised on disk.
type world struct {
	t       testing.TB
	c       scase
	scratch string
	corpus  string
	env     []string
}

var (
	farmOnce sync.Once
	farmDir  string
)

// noGitPath is a PATH directory holding a symlink to every tool of /usr/bin except git.
func noGitPath(t testing.TB) string {
	farmOnce.Do(func() {
		dir, err := os.MkdirTemp("", "ss-nogit-")
		if err != nil {
			panic(err)
		}
		ents, err := os.ReadDir("/usr/bin")
		if err != nil {
			panic(err)
		}
		for _, e := range ents {
			if e.Name() != "git" && !strings.HasPrefix(e.Name(), "git-") {
				_ = os.Symlink("/usr/bin/"+e.Name(), filepath.Join(dir, e.Name()))
			}
		}
		farmDir = dir
	})
	return farmDir
}

func newWorld(t testing.TB, c scase) *world {
	t.Helper()
	if c.skipRoot && os.Geteuid() == 0 {
		t.Skip("permission bits do not bind root")
	}
	scratch, err := os.MkdirTemp("/tmp", "ss-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(scratch) })
	w := &world{t: t, c: c, scratch: scratch, corpus: filepath.Join(scratch, "corpus")}
	w.mkdir("corpus")
	w.mkdir("tmp")
	path := os.Getenv("PATH")
	if c.noGit {
		path = noGitPath(t)
	}
	w.env = append(gitfixture.Env([]string{
		"PATH=" + path, "HOME=" + scratch, "TMPDIR=" + scratch + "/tmp", "LC_ALL=C",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z",
	}), c.env...)
	if c.build != nil {
		c.build(w)
	}
	return w
}

func (w *world) abs(rel string) string { return filepath.Join(w.corpus, rel) }

func (w *world) mkdir(rel string) {
	w.t.Helper()
	if err := os.MkdirAll(filepath.Join(w.scratch, rel), 0o755); err != nil {
		w.t.Fatal(err)
	}
}

// write creates a corpus file (parents included).
func (w *world) write(rel, content string) { w.writeBytes(rel, []byte(content)) }

func (w *world) writeBytes(rel string, b []byte) {
	w.t.Helper()
	p := w.abs(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) symlink(target, rel string) {
	w.t.Helper()
	p := w.abs(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.Symlink(target, p); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) chmod(rel string, mode os.FileMode) {
	w.t.Helper()
	if err := os.Chmod(w.abs(rel), mode); err != nil {
		w.t.Fatal(err)
	}
}

// git runs a version-control command in the corpus (or dir, when given relative to the scratch directory).
func (w *world) git(args ...string) string { return w.gitIn(w.corpus, nil, args...) }

func (w *world) gitIn(dir string, stdin []byte, args ...string) string {
	return w.gitRun(dir, w.env, stdin, args...)
}

// gitEnv runs a command in the corpus with extra environment entries (they win over the world's).
func (w *world) gitEnv(extra []string, args ...string) string {
	return w.gitRun(w.corpus, append(append([]string{}, w.env...), extra...), nil, args...)
}

func (w *world) gitRun(dir string, env []string, stdin []byte, args ...string) string {
	w.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir, cmd.Env = dir, env
	cmd.Stdin = bytes.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	if err != nil {
		w.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// initRepo makes the corpus a repository on branch main.
func (w *world) initRepo() { w.git("init", "-q", "-b", "main") }

// commit stages everything and commits with msg.
func (w *world) commit(msg string) {
	w.git("add", "-A", "-f")
	w.git("commit", "-q", "--allow-empty", "-m", msg)
}

// norm replaces the scratch path so reports compare across runs.
func (w *world) norm(s string) string { return strings.ReplaceAll(s, w.scratch, "{{S}}") }
