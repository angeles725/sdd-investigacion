package sweep

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// world is one hermetic sandbox: a kit directory holding TARGETS.md and the targets beside it. The clock of
// every Go run is w.now, taken once when the world is built; the fixtures date their files relative to it, so a
// run never depends on the day it is made (the differential runs the script on the real clock, a few seconds
// later, and every fixture keeps a margin of hours or days around each threshold).
type world struct {
	t    *testing.T
	root string
	kit  string
	env  map[string]string
	now  time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, kit: root + "/kit", now: time.Now().Truncate(time.Second)}
	if err := os.MkdirAll(w.kit+"/toolbelt", 0o755); err != nil {
		t.Fatal(err)
	}
	home := root + "/home"
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	w.env = map[string]string{
		"PATH": os.Getenv("PATH"), "HOME": home, "LC_ALL": "C",
		"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
		// The wiring pass walks up from a target to find its git root; stop at the sandbox so an enclosing
		// repository (this kit checkout) never bleeds into a fixture, and never read a real launch history.
		"RSDD_HOOK_WIRING_CEILING": filepath.Dir(root), "RSDD_CLAUDE_PROJECTS_DIR": "/nonexistent/rsdd-claude-history",
	}
	return w
}

func (w *world) getenv(k string) string { return w.env[k] }

func (w *world) environ() []string {
	var out []string
	for k, v := range w.env {
		out = append(out, k+"="+v)
	}
	return out
}

func (w *world) must(err error) {
	w.t.Helper()
	if err != nil {
		w.t.Fatal(err)
	}
}

// put writes content to an absolute path, creating its directories.
func (w *world) put(path, content string) {
	w.t.Helper()
	w.must(os.MkdirAll(filepath.Dir(path), 0o755))
	w.must(os.WriteFile(path, []byte(content), 0o644))
}

// tgt makes (and returns) the target directory <root>/<name>.
func (w *world) tgt(name string) string {
	w.t.Helper()
	p := w.root + "/" + name
	w.must(os.MkdirAll(p, 0o755))
	return p
}

// targets writes the TARGETS.md of the kit: one table row per path, each a backtick-wrapped token.
func (w *world) targets(paths ...string) {
	w.t.Helper()
	var b strings.Builder
	b.WriteString("# targets\n\n| # | name | path |\n|---|---|---|\n")
	for i, p := range paths {
		fmt.Fprintf(&b, "| %d | t%d | `%s` |\n", i+1, i+1, p)
	}
	w.put(w.kit+"/TARGETS.md", b.String())
}

// retroText is the body of the standard test retro: an optional marker line, then n numbered delta rows.
func retroText(marker string, n int) string {
	var b strings.Builder
	if marker != "" {
		b.WriteString(marker + "\n")
	}
	b.WriteString("# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n")
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "| %d | delta %d | because |\n", i, i)
	}
	return b.String()
}

// retro writes <tgt>/retros/<name>.
func (w *world) retro(tgt, name, marker string, n int) {
	w.t.Helper()
	w.put(tgt+"/retros/"+name, retroText(marker, n))
}

// wire makes the target's Stop hook run retro-gate, so the wiring pass stays quiet.
func (w *world) wire(tgt string) {
	w.t.Helper()
	w.put(tgt+"/.claude/settings.json", `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}`+"\n")
}

func (w *world) ago(d time.Duration) time.Time { return w.now.Add(-d) }

const (
	hour = time.Hour
	day  = 24 * time.Hour
	// deepPast is far enough back that any retro dated there is past every age threshold a test sets.
	deepPast = 30 * 365 * day
)

// touch sets a file's mtime to d before the world's now.
func (w *world) touch(path string, d time.Duration) {
	w.t.Helper()
	w.must(os.Chtimes(path, w.ago(d), w.ago(d)))
}

// git runs git in dir with the sandbox environment.
func (w *world) git(dir string, extraEnv []string, args ...string) {
	w.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=tester", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Env = append(w.environ(), extraEnv...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		w.t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out.String())
	}
}

// commit stages everything in dir (a repository is made on first use) and commits it d before now.
func (w *world) commit(dir string, d time.Duration, msg string) {
	w.t.Helper()
	if _, err := os.Stat(dir + "/.git"); err != nil {
		w.git(dir, nil, "init", "-q")
	}
	date := fmt.Sprintf("%d +0000", w.ago(d).Unix())
	w.git(dir, nil, "add", "-A")
	w.git(dir, []string{"GIT_AUTHOR_DATE=" + date, "GIT_COMMITTER_DATE=" + date}, "commit", "-q", "-m", msg)
}

// result is one run.
type result struct {
	out, err string
	rc       int
}

// run runs `rsdd sweep retros --kit <kit> <args>` in process.
func (w *world) run(args ...string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := cli.Run(Commands, append([]string{"sweep", "retros", "--kit", w.kit}, args...), w.stdio(&o, &e))
	return result{o.String(), e.String(), rc}
}

// runHook runs `rsdd sweep retros --hook`.
func (w *world) runHook(args ...string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := cli.Run(Commands, append([]string{"sweep", "retros", "--hook", "--kit", w.kit}, args...), w.stdio(&o, &e))
	return result{o.String(), e.String(), rc}
}

// stdio is the injected process boundary of a Go run: the world's environment and its fixed clock.
func (w *world) stdio(o, e io.Writer) cli.Stdio {
	return cli.Stdio{In: strings.NewReader(""), Out: o, Err: e, Env: w.getenv, Environ: w.environ,
		Clock: func() time.Time { return w.now }, Cwd: w.root}
}

// expand replaces the placeholders of an expectation: {A} {B} {C} are <root>/targetA .. targetC and {kit} the kit.
func (w *world) expand(s string) string {
	return strings.NewReplacer("{root}", w.root, "{A}", w.root+"/targetA", "{B}", w.root+"/targetB", "{C}", w.root+"/targetC", "{kit}", w.kit).Replace(s)
}
