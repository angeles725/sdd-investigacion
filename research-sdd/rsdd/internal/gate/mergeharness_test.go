package gate

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// This file is the process-level rig: real git repositories, the bash suite's own stub `gentle-ai` and `gh`
// (testdata/merge/stubs) on PATH, and two ways to run one scenario: the frozen original (testdata/legacy) and
// RunMerge with the real runner. The differential test compares them; the smoke test checks RunMerge alone.
// No build tag: gremlins builds the package with `nodiff`, and this file must compile there.

const (
	stubDir   = "testdata/merge/stubs"
	legacyBin = "testdata/legacy/merge-gate.sh"
)

type world struct {
	t     *testing.T
	root  string
	stubs string
	repos map[string]string // key -> directory
	sha   map[string]string // "<key>:<rev>" -> full sha
	files int
	runs  int
}

func mustRun(t *testing.T, dir string, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func newWorld(t *testing.T) *world {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	w := &world{t: t, root: t.TempDir(), repos: map[string]string{}, sha: map[string]string{}}
	abs, err := filepath.Abs(stubDir)
	if err != nil {
		t.Fatal(err)
	}
	w.stubs = abs
	return w
}

func (w *world) git(repo string, args ...string) string {
	return mustRun(w.t, w.repos[repo], "git", args...)
}

func (w *world) commit(repo, msg string) {
	w.git(repo, "commit", "-q", "--allow-empty", "-m", msg)
}

// initRepo creates an empty repository on branch main.
func (w *world) initRepo(key string) string {
	dir := filepath.Join(w.root, "repo-"+key)
	w.repos[key] = dir
	if err := os.MkdirAll(dir, 0o755); err != nil {
		w.t.Fatal(err)
	}
	mustRun(w.t, dir, "git", "init", "-q", "-b", "main")
	return dir
}

func (w *world) rev(repo, rev string) string {
	k := repo + ":" + rev
	if s, ok := w.sha[k]; ok {
		return s
	}
	s := w.git(repo, "rev-parse", rev)
	w.sha[k] = s
	return s
}

// revOpt is rev, or "" when the revision does not exist (an unborn HEAD, a missing tag).
func (w *world) revOpt(repo, rev string) string {
	cmd := exec.Command("git", "rev-parse", "--verify", "--quiet", rev)
	cmd.Dir = w.repos[repo]
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func (w *world) write(path, content string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// file writes content to a fresh file under the root and returns its path.
func (w *world) file(content string) string {
	w.files++
	p := filepath.Join(w.root, "data", fmt.Sprintf("f%04d", w.files))
	w.write(p, content)
	return p
}

// buildRepos creates the repositories of the bash suite: repo (base tag, head commit), r2 (main moved ahead of the
// branch point, feat checked out), r3 (a dangerous commit and a harmless one on top of c0), r0 (unborn HEAD) and
// orphan (no common ancestor with r2's feat, fetched as `other`).
func (w *world) buildRepos() {
	w.initRepo("repo")
	w.write(filepath.Join(w.repos["repo"], "a"), "a\n")
	w.git("repo", "add", "a")
	w.commit("repo", "base")
	w.git("repo", "tag", "base")
	w.write(filepath.Join(w.repos["repo"], "b"), "b\n")
	w.git("repo", "add", "b")
	w.commit("repo", "head")

	w.initRepo("r2")
	w.commit("r2", "c0")
	w.git("r2", "tag", "c0")
	w.git("r2", "checkout", "-q", "-b", "feat")
	w.commit("r2", "f1")
	w.git("r2", "checkout", "-q", "main")
	w.commit("r2", "m1")
	w.git("r2", "checkout", "-q", "feat")

	w.initRepo("r3")
	w.commit("r3", "c0")
	w.git("r3", "tag", "c0")
	w.commit("r3", "d1-danger")
	w.commit("r3", "d2-docs")

	w.initRepo("r0")

	w.initRepo("orphan")
	w.commit("orphan", "o0")
	w.git("orphan", "fetch", "-q", w.repos["r2"], "feat:other")
	w.git("r3", "fetch", "-q", w.repos["orphan"], "main:orphan")
}

// workflowRepo builds a repository whose PR base (tag base) carries the base workflow and whose HEAD the head
// workflow, both as .github/workflows/toolbelt-tests.yml; extra maps more workflow file names to texts (in both).
func (w *world) workflowRepo(key, baseWF, headWF string, extra map[string]string) {
	dir := w.initRepo(key)
	wf := filepath.Join(dir, ".github", "workflows")
	w.write(filepath.Join(wf, "toolbelt-tests.yml"), baseWF)
	var names []string
	for n := range extra {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		w.write(filepath.Join(wf, n), extra[n])
	}
	w.git(key, "add", "-A")
	w.commit(key, "c0")
	w.git(key, "tag", "base")
	w.write(filepath.Join(wf, "toolbelt-tests.yml"), headWF)
	w.git(key, "add", "-A")
	w.commit(key, "head")
}

// dsc is one scenario. Args and Env values may use {R} (the repository directory), {ROOT}, {HEAD}, {BASE} and
// {PRB} (the stub PR base) placeholders.
type dsc struct {
	name  string
	repo  string
	args  []string
	env   []string
	path  string // "" = the stubs then the caller's PATH; else a directory name under root/bin holding only some tools
	fresh bool   // run against a private clone of the repo (a scenario that moves HEAD)
	// base and head override the sha placeholders
	prBase string
}

type mgResult struct {
	out, err string
	rc       int
	log      string
	side     map[string]string
}

func (w *world) expand(s string, repoDir, runDir string, sc dsc) string {
	head, base := "", ""
	if sc.repo != "" {
		head = w.revOpt(sc.repo, "HEAD")
		if t, ok := baseTagOf(sc.repo); ok {
			base = w.revOpt(sc.repo, t)
		}
	}
	prb := sc.prBase
	if prb == "" {
		prb = base
	}
	return strings.NewReplacer("{R}", repoDir, "{ROOT}", w.root, "{HEAD}", head, "{BASE}", base, "{PRB}", prb, "{ORPHAN}", w.orphan(), "{RUN}", runDir).Replace(s)
}

func (w *world) orphan() string {
	if _, ok := w.repos["orphan"]; !ok {
		return ""
	}
	return w.revOpt("orphan", "HEAD")
}

func baseTagOf(repo string) (string, bool) {
	switch repo {
	case "repo":
		return "base", true
	case "r2", "r3":
		return "c0", true
	}
	return "base", true
}

// miniPath returns the directory holding only the named tools, created once.
func (w *world) miniPath(name string, tools ...string) string {
	d := filepath.Join(w.root, "bin-"+name)
	if _, err := os.Stat(d); err == nil {
		return d
	}
	if err := os.MkdirAll(d, 0o755); err != nil {
		w.t.Fatal(err)
	}
	for _, tool := range tools {
		p, err := exec.LookPath(tool)
		if err != nil {
			w.t.Fatalf("%s not found", tool)
		}
		if err := os.Symlink(p, filepath.Join(d, tool)); err != nil {
			w.t.Fatal(err)
		}
	}
	return d
}

func (w *world) environFor(sc dsc, repoDir, runDir string) []string {
	pathVal := w.stubs + ":" + os.Getenv("PATH")
	switch sc.path {
	case "":
	case "nojq":
		d := w.miniPath("nojq", "git", "bash", "env", "cat", "dirname", "mktemp", "rm")
		_ = os.Symlink(filepath.Join(w.stubs, "gentle-ai"), filepath.Join(d, "gentle-ai"))
		pathVal = d
	case "nogentle":
		pathVal = w.miniPath("nogentle", "git", "jq", "bash", "env", "cat", "dirname", "mktemp", "rm")
	case "nogit":
		d := w.miniPath("nogit", "jq", "bash", "env", "cat", "dirname", "mktemp", "rm")
		_ = os.Symlink(filepath.Join(w.stubs, "gentle-ai"), filepath.Join(d, "gentle-ai"))
		pathVal = d
	case "nogh":
		d := w.miniPath("nogh", "git", "jq", "bash", "env", "cat", "dirname", "mktemp", "rm", "head", "cut", "grep")
		_ = os.Symlink(filepath.Join(w.stubs, "gentle-ai"), filepath.Join(d, "gentle-ai"))
		pathVal = d
	default:
		w.t.Fatalf("unknown path mode %q", sc.path)
	}
	env := []string{"PATH=" + pathVal, "HOME=" + w.root, "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "TMPDIR=" + w.root,
		"STUB_LOG=" + filepath.Join(runDir, "log"), "STUB_COMMENTS=" + filepath.Join(runDir, "comments")}
	for _, e := range sc.env {
		env = append(env, w.expand(e, repoDir, runDir, sc))
	}
	return env
}

// prepare creates the run directory and, for a fresh scenario, the private clone.
// prepMu serialises the run counter: the differential runs its scenarios in parallel.
var prepMu sync.Mutex

func (w *world) prepare(sc dsc, kind string) (repoDir, runDir string) {
	prepMu.Lock()
	w.runs++
	n := w.runs
	prepMu.Unlock()
	runDir = filepath.Join(w.root, fmt.Sprintf("run-%s-%04d", kind, n))
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		w.t.Fatal(err)
	}
	if sc.repo != "" {
		repoDir = w.repos[sc.repo]
	}
	if sc.fresh {
		repoDir = filepath.Join(runDir, "clone")
		mustRun(w.t, w.root, "git", "clone", "-q", w.repos[sc.repo], repoDir)
	}
	return repoDir, runDir
}

func (w *world) collect(res *mgResult, runDir string) {
	b, _ := os.ReadFile(filepath.Join(runDir, "log"))
	res.log = strings.ReplaceAll(string(b), runDir, "{RUN}")
	res.side = map[string]string{}
	ents, _ := os.ReadDir(runDir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "comments") {
			c, _ := os.ReadFile(filepath.Join(runDir, e.Name()))
			res.side[e.Name()] = string(c)
		}
	}
}

func (w *world) args(sc dsc, repoDir, runDir string) []string {
	var out []string
	for _, a := range sc.args {
		out = append(out, w.expand(a, repoDir, runDir, sc))
	}
	return out
}

// runLegacy runs the frozen bash original.
func (w *world) runLegacy(sc dsc) mgResult {
	repoDir, runDir := w.prepare(sc, "legacy")
	abs, _ := filepath.Abs(legacyBin)
	cmd := exec.Command("bash", append([]string{abs}, w.args(sc, repoDir, runDir)...)...)
	cmd.Env = w.environFor(sc, repoDir, runDir)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		w.t.Fatal(err)
	}
	res := mgResult{out: o.String(), err: e.String(), rc: rc}
	w.collect(&res, runDir)
	return norm(res, repoDir, runDir)
}

// runGo runs RunMerge with the real runner.
func (w *world) runGo(sc dsc) mgResult {
	repoDir, runDir := w.prepare(sc, "go")
	environ := w.environFor(sc, repoDir, runDir)
	cwd, _ := os.Getwd()
	var o, e bytes.Buffer
	s := cli.Stdio{Out: &o, Err: &e, Cwd: cwd, Environ: func() []string { return environ }, Env: func(k string) string {
		v, _ := environLookup(environ, k)
		return v
	}}
	rc := RunMerge(w.args(sc, repoDir, runDir), s)
	res := mgResult{out: o.String(), err: e.String(), rc: rc}
	w.collect(&res, runDir)
	return norm(res, repoDir, runDir)
}

// norm replaces the per-run paths so two runs of one scenario compare equal.
func norm(r mgResult, repoDir, runDir string) mgResult {
	fix := func(s string) string {
		s = strings.ReplaceAll(s, runDir, "{RUN}")
		if repoDir != "" && strings.Contains(repoDir, "clone") {
			s = strings.ReplaceAll(s, repoDir, "{R}")
		}
		return s
	}
	r.out, r.err, r.log = fix(r.out), fix(r.err), fix(r.log)
	for k, v := range r.side {
		r.side[k] = fix(v)
	}
	return r
}

// dropDegraded removes the `DEGRADED: <why>` line the rsdd process contract adds to stderr on exit 3; why is the
// text of the last degraded verdict on stdout.
func dropDegraded(errText, out string) string {
	i := strings.LastIndex(out, "merge-gate: degraded: ")
	if i < 0 {
		return errText
	}
	why := strings.TrimSuffix(out[i+len("merge-gate: degraded: "):], "\n")
	return strings.Replace(errText, "DEGRADED: "+why+"\n", "", 1)
}

func (w *world) assessFile(due, reason string) string { return w.file(assessJSON(due, reason)) }

// dropJQ removes the diagnostics jq itself prints to stderr.
func dropJQ(s string) string {
	var keep []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if !strings.HasPrefix(l, "jq: error") && !strings.HasPrefix(l, "jq: parse error") && !strings.Contains(l, "integer expression expected") {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "")
}
