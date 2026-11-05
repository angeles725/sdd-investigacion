package cleancheck

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// world is one hermetic case: a repository (repo), a tmp directory (tmp) and a scratch directory (scratch), all below
// one physical root. Every path a test prints is shown with the root replaced by <R>.
type world struct {
	t       *testing.T
	root    string
	repo    string
	tmp     string
	scratch string
	home    string
	env     []string
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, repo: root + "/repo", tmp: root + "/tmp", scratch: root + "/scratch", home: root + "/home"}
	for _, d := range []string{w.repo, w.tmp, w.scratch, w.home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w.env = gitfixture.Env([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + w.home, "LC_ALL=C", "TZ=UTC",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_CONFIG_NOSYSTEM=1"})
	w.git("init", "-q", "-b", "main")
	w.write("tracked.txt", "tracked\n")
	w.git("add", "tracked.txt")
	w.commit("init")
	return w
}

// git runs git in the repository and fails the test when it fails.
func (w *world) git(args ...string) string {
	w.t.Helper()
	return w.gitIn(w.repo, args...)
}

func (w *world) gitIn(dir string, args ...string) string {
	w.t.Helper()
	c := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"}, args...)...)
	c.Env = w.env
	out, err := c.CombinedOutput()
	if err != nil {
		w.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func (w *world) commit(msg string) { w.t.Helper(); w.git("commit", "-q", "--allow-empty", "-m", msg) }

// write creates a file below the repository (parents included).
func (w *world) write(rel, body string) { w.t.Helper(); w.writeAt(filepath.Join(w.repo, rel), body) }

func (w *world) writeAt(path, body string) {
	w.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) mkdir(path string) {
	w.t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		w.t.Fatal(err)
	}
}

// ago sets the mtime of path to hours (fractions allowed) before now.
func (w *world) ago(hours float64, path string) {
	w.t.Helper()
	at := time.Now().Add(-time.Duration(hours * float64(time.Hour)))
	if err := os.Chtimes(path, at, at); err != nil {
		w.t.Fatal(err)
	}
}

// show replaces the world root with <R>.
func (w *world) show(s string) string { return strings.ReplaceAll(s, w.root, "<R>") }

// optionsFor turns legacy arguments into the engine's options (the command does this in production).
func (w *world) optionsFor(extraEnv []string, args ...string) Options {
	w.t.Helper()
	o := Options{Cwd: w.root, Env: w.env, Now: time.Now, StaleHours: DefaultStaleHours, BackupDays: DefaultBackupDays}
	for _, kv := range extraEnv {
		switch {
		case strings.HasPrefix(kv, "CLEAN_CHECK_UID="):
			o.UID = strings.TrimPrefix(kv, "CLEAN_CHECK_UID=")
		case strings.HasPrefix(kv, "CLEAN_CHECK_SCRATCHPAD="):
			o.Scratchpad = strings.TrimPrefix(kv, "CLEAN_CHECK_SCRATCHPAD=")
		case strings.HasPrefix(kv, "PATH="):
			o.Env = append(append([]string(nil), o.Env...), kv)
		}
	}
	for i := 0; i+1 < len(args); i += 2 {
		v := args[i+1]
		switch args[i] {
		case "--target":
			o.Target = v
		case "--tmp":
			o.Tmp = v
		case "--scratchpad":
			o.Scratchpad = v
		case "--base":
			o.Base = v
		case "--evidence":
			o.Evidence = v
		case "--stale-hours":
			o.StaleHours = atoi(w.t, v)
		case "--backup-days":
			o.BackupDays = atoi(w.t, v)
		default:
			w.t.Fatalf("optionsFor: unknown flag %s", args[i])
		}
	}
	return o
}

func atoi(t *testing.T, s string) int {
	t.Helper()
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			t.Fatalf("not a number: %q", s)
		}
		n = n*10 + int(c-'0')
	}
	return n
}
