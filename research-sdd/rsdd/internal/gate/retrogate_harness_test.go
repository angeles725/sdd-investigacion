package gate

import (
	"bytes"
	"fmt"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// The rig of the retro-gate tests: a world is a temp root holding a staged toolbelt (the live lib/ and
// verify-retro.sh, a stub stage-retro-issues.sh, a mock gh) and the fixture targets. A scenario builds its
// fixtures through the world, returns the runs to make, and checks the results. The same scenario runs
//   - against runRetro alone (retrogate_cases_test.go, no build tag: CI teeth build the package with `nodiff`),
//   - against the frozen original script too (retrogate_diff_test.go, staged by retrogate_legacy_test.go), which must agree on
//     stdout, stderr, the exit code and every state file, and must itself satisfy the scenario's own checks.
// Nothing here needs python3 or bwrap; bash, git, find and jq are the only tools.

const (
	rgLiveTB  = "../../../toolbelt"
	rgSession = "202609050800"
)

type rgWorld struct {
	t       *testing.T
	root    string
	tb      string // staged toolbelt
	stubs   string // first on PATH: gh
	seedLog string
	bash    bool // the world of a bash run (the staged retro-gate.sh is the frozen original)
}

func newRGWorld(t *testing.T, bash bool) *rgWorld {
	t.Helper()
	for _, tool := range []string{"git", "bash", "jq", "find"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not on PATH", tool)
		}
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &rgWorld{t: t, root: root, tb: root + "/kit/toolbelt", stubs: root + "/stubs", seedLog: root + "/seed.log", bash: bash}
	for _, d := range []string{w.tb, w.stubs, root + "/home", root + "/tmp"} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	live, err := filepath.Abs(rgLiveTB)
	if err != nil {
		t.Fatal(err)
	}
	must(t, os.Symlink(live+"/lib", w.tb+"/lib"))
	must(t, os.Symlink(live+"/verify-retro.sh", w.tb+"/verify-retro.sh"))
	if rgStageLegacy != nil {
		rgStageLegacy(w)
	}
	w.seeder("printf '%s\\n' \"$*\" >> \"${SEED_LOG:-/dev/null}\"\nprintf 'summary: created=0 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0\\n'\nexit 0\n")
	w.script(w.stubs+"/gh", "exit 0\n")
	return w
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (w *rgWorld) write(p, content string) {
	w.t.Helper()
	must(w.t, os.MkdirAll(filepath.Dir(p), 0o755))
	must(w.t, os.WriteFile(p, []byte(content), 0o644))
}

// script writes an executable through execfile.Write: the parallel subtests fork while worlds are built, and a stub
// written with a plain WriteFile can fail to exec with ETXTBSY (#2697).
func (w *rgWorld) script(p, body string) {
	w.t.Helper()
	execfile.Write(w.t, p, "#!/usr/bin/env bash\n"+body)
}

// seeder replaces the staged stage-retro-issues.sh.
func (w *rgWorld) seeder(body string) { w.script(w.tb+"/stage-retro-issues.sh", body) }

func (w *rgWorld) baseEnv() map[string]string {
	return map[string]string{
		"PATH": w.stubs + ":" + os.Getenv("PATH"), "HOME": w.root + "/home", "LC_ALL": "C", "TMPDIR": w.root + "/tmp",
		"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
		"SEED_LOG": w.seedLog, "RSDD_CLAUDE_PROJECTS_DIR": "/nonexistent/rsdd-claude-history", "RSDD_BIN": rgRsddBin(w.t),
	}
}

func (w *rgWorld) git(dir string, args ...string) string {
	return w.gitAt(dir, "", args...)
}

func (w *rgWorld) gitAt(dir, date string, args ...string) string {
	w.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	env := w.baseEnv()
	if date != "" {
		env["GIT_AUTHOR_DATE"], env["GIT_COMMITTER_DATE"] = date, date
	}
	cmd.Env = gitfixture.Env(envList(env))
	out, err := cmd.CombinedOutput()
	if err != nil {
		w.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func envList(m map[string]string) []string {
	var out []string
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

// mkgit makes a hermetic repository with one baseline commit and returns its absolute path.
func (w *rgWorld) mkgit(rel string) string {
	w.t.Helper()
	d := filepath.Join(w.root, rel)
	must(w.t, os.MkdirAll(d, 0o755))
	if _, err := os.Stat(d + "/.git"); err != nil {
		w.git(d, "init", "-q", "-b", "main")
		w.write(d+"/.gitkeep", "")
		w.git(d, "add", "-A")
		w.gitAt(d, "2026-01-01T00:00:00", "commit", "-q", "-m", "init")
	}
	return d
}

// touch is `touch -t YYYYMMDDHHMM path`.
func (w *rgWorld) touch(p, stamp string) {
	w.t.Helper()
	ts, err := time.ParseInLocation("200601021504", stamp, time.Local)
	must(w.t, err)
	must(w.t, os.Chtimes(p, ts, ts))
}

// session records the current HEAD as the session start (before the block commit) and optionally dates the file.
func (w *rgWorld) session(dir, sid, stamp string) {
	w.t.Helper()
	w.write(dir+"/.claude/.rsdd-session-"+sid, w.git(dir, "rev-parse", "HEAD")+"\n")
	if stamp != "" {
		w.touch(dir+"/.claude/.rsdd-session-"+sid, stamp)
	}
}

func (w *rgWorld) block(dir, name, gdate string) {
	w.t.Helper()
	w.write(dir+"/"+name, "# Block — test\n\nContent.\n")
	w.git(dir, "add", name)
	w.gitAt(dir, gdate, "commit", "-q", "-m", "add "+name)
}

const rgConformingRetro = "<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta fixture row | file.sh | evidence | fix | low |\n"

// retro writes an uncommitted retro under <dir>/retros.
func (w *rgWorld) retro(dir, fname string, conforming bool) string {
	w.t.Helper()
	p := dir + "/retros/" + fname
	if conforming {
		w.write(p, rgConformingRetro)
	} else {
		w.write(p, "# Retro — test\n\nSome notes.\n")
	}
	return p
}

func (w *rgWorld) retroCommitted(dir, fname, gdate string) {
	w.t.Helper()
	w.retro(dir, fname, true)
	w.git(dir, "add", "retros/"+fname)
	w.gitAt(dir, gdate, "commit", "-q", "-m", "add "+fname)
}

func mkjson(sid string, active bool) string {
	return fmt.Sprintf(`{"session_id":"%s","stop_hook_active":%t,"hook_event_name":"Stop","cwd":"/tmp"}`, sid, active)
}

// ── runs and results ─────────────────────────────────────────────────────────

type rgRun struct {
	args  []string
	stdin string
	env   map[string]string // overrides of baseEnv; a value of "-" removes the variable
	path  string            // replaces PATH entirely when set
	// target is the directory whose .claude state the result reports.
	target string
	hooks  retroHooks
	// before runs just before this run (a test dates a file, drops a state file).
	before func()
}

// gate is the plain run: stdin is the Stop hook JSON, args the target.
func gate(target, sid string) rgRun {
	return rgRun{args: []string{target}, stdin: mkjson(sid, false), target: target}
}

func (r rgRun) json() rgRun { r.args = append([]string{"--json"}, r.args...); return r }

func (r rgRun) withEnv(k, v string) rgRun {
	m := map[string]string{}
	for a, b := range r.env {
		m[a] = b
	}
	m[k] = v
	r.env = m
	return r
}

type rgRes struct {
	out, err string
	rc       int
	tree     map[string]string // every file under <target>/.claude, normalised
	seeded   []string          // the lines the stub seeder logged
}

func (r *rgRes) blocked() bool { return strings.Contains(r.out, `"decision":"block"`) }
func (r *rgRes) stopLog() string {
	return r.tree[".rsdd-retro-gate-stops.log"]
}
func (r *rgRes) lastLog() string {
	ls := strings.Split(strings.TrimRight(r.stopLog(), "\n"), "\n")
	return ls[len(ls)-1]
}

var (
	reTS   = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ`)
	reDate = regexp.MustCompile(`/retros/\d{4}-\d\d-\d\d-<focus>`)
	// reShellDiag is a diagnostic of the bash shell itself: a failed `> file 2>/dev/null` prints its error before the
	// 2>/dev/null applies. The port is silent there, which is what the redirection meant.
	reShellDiag = regexp.MustCompile(`(?m)^<R>/kit/toolbelt/retro-gate\.sh: line \d+: [^\n]*\n`)
)

func (w *rgWorld) norm(s string) string {
	s = strings.ReplaceAll(s, w.root, "<R>")
	s = reShellDiag.ReplaceAllString(s, "")
	s = reTS.ReplaceAllString(s, "<TS>")
	return reDate.ReplaceAllString(s, "/retros/<D>-<focus>")
}

func (w *rgWorld) envFor(r rgRun) map[string]string {
	env := w.baseEnv()
	if r.path != "" {
		env["PATH"] = r.path
	}
	for k, v := range r.env {
		if v == "-" {
			delete(env, k)
		} else {
			env[k] = v
		}
	}
	return env
}

func (w *rgWorld) collect(r rgRun, out, errs string, rc int) *rgRes {
	res := &rgRes{out: w.norm(out), err: w.norm(errs), rc: rc, tree: map[string]string{}}
	if r.target != "" {
		base := r.target + "/.claude"
		_ = filepath.WalkDir(base, func(p string, d os.DirEntry, err error) error {
			if err == nil && p != base && d.Type().IsRegular() {
				b, _ := os.ReadFile(p)
				name := strings.TrimPrefix(p, base+"/")
				if strings.HasPrefix(name, ".rsdd-session-") { // written by the fixture, not by the gate: shas differ per root
					b = []byte("<session>")
				}
				res.tree[name] = w.norm(string(b))
			}
			return nil
		})
	}
	if b, err := os.ReadFile(w.seedLog); err == nil {
		for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
			res.seeded = append(res.seeded, w.norm(l))
		}
	}
	return res
}

// runGo runs the port in-process with a real clock (the bash reads the real one too).
func (w *rgWorld) runGo(r rgRun) *rgRes {
	w.t.Helper()
	env := w.envFor(r)
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(r.stdin), Out: &out, Err: &errb,
		Env:     func(k string) string { return env[k] },
		Environ: func() []string { return envList(env) },
		Clock:   time.Now, Cwd: w.root,
	}
	rc := runRetro(append([]string{"--toolbelt", w.tb}, r.args...), s, r.hooks)
	return w.collect(r, out.String(), errb.String(), rc)
}

// The bash side of the harness (staging and running the frozen original) lives in retrogate_legacy_test.go,
// which is built without `nodiff` only: CI teeth build this package with `nodiff` and must never exec the oracle.
var (
	rgStageLegacy func(w *rgWorld)
	rgRunBash     func(w *rgWorld, r rgRun) *rgRes
)

func (w *rgWorld) run(r rgRun) *rgRes {
	if w.bash {
		if rgRunBash == nil {
			w.t.Fatal("a bash run needs retrogate_legacy_test.go, which -tags nodiff excludes")
		}
		return rgRunBash(w, r)
	}
	return w.runGo(r)
}

// A scenario builds fixtures in a world, returns the runs to make and checks their results (the last one is the
// verdict under test; several runs model the same session stopping more than once).
type rgCase struct {
	id string
	// goOnly marks a scenario the bash original cannot reproduce (it needs a seam of the port).
	goOnly bool
	setup  func(w *rgWorld) []rgRun
	check  func(t *testing.T, rs []*rgRes)
}

func (c rgCase) execute(t *testing.T, bash bool) []*rgRes {
	t.Helper()
	w := newRGWorld(t, bash)
	var rs []*rgRes
	for _, r := range c.setup(w) {
		if r.before != nil {
			r.before()
		}
		rs = append(rs, w.run(r))
	}
	return rs
}

func one(r rgRun) []rgRun { return []rgRun{r} }

func has(t *testing.T, what, s string, subs ...string) {
	t.Helper()
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			t.Errorf("%s: want %q in:\n%s", what, sub, s)
		}
	}
}

func lacks(t *testing.T, what, s string, subs ...string) {
	t.Helper()
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			t.Errorf("%s: unexpected %q in:\n%s", what, sub, s)
		}
	}
}

var _ = io.EOF

// ext is a directory outside the target with one block file, newer or older than the session start.
func (w *rgWorld) ext(name string, newer bool) string {
	d := w.root + "/" + name
	p := w.write0(d+"/ext-block1.md", "# Block\n")
	if newer {
		w.touch(p, "202609051000")
	} else {
		w.touch(p, "202609040800")
	}
	return d
}

// fresh is a target with a session start and no research change.
func (w *rgWorld) fresh(name, sid string) string {
	d := w.mkgit(name)
	w.session(d, sid, rgSession)
	return d
}
