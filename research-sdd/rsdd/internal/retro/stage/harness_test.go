package stage

import (
	"bytes"
	"embed"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// This file is the shared test harness. It carries no build tag: gremlins builds with -tags nodiff, and the case
// tables, the Go runner and the golden replay need it. The tagged differential_test.go adds the live legacy run.
//
// A case builds a KIT BOX: a git repository at <root>/repo that holds a copy of the frozen legacy toolbelt
// (research-sdd/toolbelt/stage-retro.sh and its libs), a bare remote at <root>/origin.git, and whatever the
// case's setup commits. The legacy run and the Go run each get their own box built by the SAME setup with a fixed
// git identity and dates, so both boxes are byte-identical and every sha is equal; the box path is replaced by
// @BOX@ in every recorded output.

//go:embed testdata/legacy
var legacyFS embed.FS

// testdata is the embedded testdata directory: the box carries the toolbelt copy so both boxes of a case hold the
// same bytes.
var testdata = mustSub(legacyFS)

func mustSub(e embed.FS) fs.FS {
	sub, err := fs.Sub(e, "testdata")
	if err != nil {
		panic(err)
	}
	return sub
}

type dcase struct {
	name string
	// setup builds the box content (retros, TARGETS.md, extra branches...); it runs on a fresh repo with an
	// origin that already holds main.
	setup func(t *testing.T, f *fx)
	// retro is the retro path relative to the repo, "targetA/retros/r1.md" when empty.
	retro string
	// args replaces the argument list (@RETRO@ is the absolute retro path, @REPO@ the repo root); nil is [@RETRO@].
	args []string
	// rel passes the retro relative to the repo and runs from the repo; cwd runs from that repo-relative dir
	// with the retro relative to it.
	rel bool
	cwd string
	// viaLink reaches the toolbelt through a symlink, the way the profile installer does (kit issue #1024).
	viaLink bool
	// keepsHead declares the one intended divergence of the checkout: the script ran `git checkout -q main` before
	// anything else, so a refusal left the kit checkout on main; the port never leaves the branch it started on.
	// For such a case the recorded state is replaced by the state before the run (nothing changed), and the
	// differential does not compare the legacy state.
	keepsHead bool
}

// fx is one box.
type fx struct {
	t                  *testing.T
	root, repo, remote string
	env                []string
	before             string // the state after setup, before the run
}

// result is what one run produced, normalised.
type result struct {
	RC     int    `json:"rc"`
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	State  string `json:"state"`
}

func newFx(t *testing.T) *fx {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fx{t: t, root: root, repo: filepath.Join(root, "repo"), remote: filepath.Join(root, "origin.git")}
	f.env = gitfixture.Env([]string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + root, "LC_ALL=C", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0", "GIT_AUTHOR_NAME=tester", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=tester", "GIT_COMMITTER_EMAIL=t@example.com",
		"GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z",
		"RESEARCH_HOME=" + filepath.Join(root, "repo"),
	})
	return f
}

// mkBox lays down the kit repo of the case: the frozen toolbelt copy, init commit, a bare origin, main pushed.
func mkBox(t *testing.T, c dcase) *fx {
	t.Helper()
	f := newFx(t)
	for _, p := range []string{"stage-retro.sh", "lib/retro-status.sh", "lib/target-paths.sh"} {
		data, err := fs.ReadFile(testdata, "legacy/"+p)
		if err != nil {
			t.Fatal(err)
		}
		f.write("research-sdd/toolbelt/"+p, string(data), 0o755)
	}
	f.git(f.repo, "init", "-q", "-b", "main")
	f.git(f.repo, "config", "branch.autoSetupMerge", "true")
	f.git(f.repo, "add", "-A")
	f.git(f.repo, "commit", "-qm", "init")
	f.git(f.root, "init", "-q", "--bare", "-b", "main", f.remote)
	f.git(f.repo, "remote", "add", "origin", f.remote)
	f.git(f.repo, "push", "-q", "origin", "main")
	if c.setup != nil {
		c.setup(t, f)
	}
	f.before = f.state()
	return f
}

// expect is what the recorded legacy result stands for on box f: itself, except for a keepsHead case, whose HEAD
// and worktree lines are the ones the box had before the run (the fetch still updates remote-tracking refs, so the
// rest of the state is the legacy one).
func (c dcase) expect(want result, f *fx) result {
	if !c.keepsHead {
		return want
	}
	before := strings.Split(f.before, "\n")
	lines := strings.Split(want.State, "\n")
	for i, l := range lines {
		for _, b := range before {
			if strings.HasPrefix(l, "HEAD ") && strings.HasPrefix(b, "HEAD ") || strings.HasPrefix(l, "@BOX@/repo ") && strings.HasPrefix(b, "@BOX@/repo ") {
				lines[i] = b
			}
		}
	}
	want.State = strings.Join(lines, "\n")
	return want
}

func (f *fx) write(rel, content string, mode os.FileMode) {
	f.t.Helper()
	p := f.abs(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		f.t.Fatal(err)
	}
}

// abs resolves a repo-relative path.
func (f *fx) abs(rel string) string { return filepath.Join(f.repo, rel) }

// git runs git in dir and fails the test when it fails.
func (f *fx) git(dir string, args ...string) string {
	f.t.Helper()
	out, err := f.gitRaw(dir, args...)
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimRight(out, "\n")
}

func (f *fx) gitRaw(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = f.env
	var b bytes.Buffer
	cmd.Stdout, cmd.Stderr = &b, &b
	err := cmd.Run()
	return b.String(), err
}

// commitAll commits everything and pushes main (the retro must be reachable from origin/main, or the
// self-referential guard refuses).
func (f *fx) commitAll(msg string, push bool) {
	f.t.Helper()
	f.git(f.repo, "add", "-A")
	f.git(f.repo, "commit", "-qm", msg)
	if push {
		f.git(f.repo, "push", "-q", "origin", "main")
	}
}

// resolve substitutes the argument placeholders of the case.
func (c dcase) resolve(f *fx) (args []string, cwd string) {
	retro := c.retro
	if retro == "" {
		retro = "targetA/retros/r1.md"
	}
	cwd = f.repo
	switch {
	case c.rel:
		return []string{retro}, f.repo
	case c.cwd != "":
		cwd = f.abs(c.cwd)
		rel, _ := filepath.Rel(cwd, f.abs(retro))
		return []string{rel}, cwd
	case c.args != nil:
		for _, a := range c.args {
			args = append(args, strings.NewReplacer("@RETRO@", f.abs(retro), "@REPO@", f.repo, "@BOX@", f.root).Replace(a))
		}
		return args, cwd
	}
	return []string{f.abs(retro)}, cwd
}

// toolbelt is the directory the command is told it lives in: the repo's, or a symlink to it.
func (c dcase) toolbelt(f *fx) string {
	real := f.abs("research-sdd/toolbelt")
	if !c.viaLink {
		return real
	}
	link := filepath.Join(f.root, "profile", "research-sdd", "profile", "myprofile", "toolbelt")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		f.t.Fatal(err)
	}
	return link
}

var reShortSHA = regexp.MustCompile(`(\.md)@[0-9a-f]{7,40}`)

// normalize replaces the box path and the abbreviated sha of the Retro: trailer (its length follows the host's
// git configuration).
func (f *fx) normalize(s string) string {
	s = strings.ReplaceAll(s, f.root, "@BOX@")
	return reShortSHA.ReplaceAllString(s, "$1@<sha>")
}

// state is the repository after a run: where HEAD is, every ref with its sha and upstream, the working tree and
// index status, the worktrees and the branch config. A refusal must leave it equal to the state before.
func (f *fx) state() string {
	f.t.Helper()
	var b strings.Builder
	head, err := f.gitRaw(f.repo, "symbolic-ref", "-q", "HEAD")
	if err != nil {
		head, _ = f.gitRaw(f.repo, "rev-parse", "HEAD")
	}
	b.WriteString("HEAD " + strings.TrimSpace(head) + "\n")
	b.WriteString("refs:\n" + f.git(f.repo, "for-each-ref", "--format=%(refname) %(objectname) upstream=%(upstream)") + "\n")
	b.WriteString("status:\n" + f.git(f.repo, "status", "--porcelain") + "\n")
	b.WriteString("worktrees:\n" + f.git(f.repo, "worktree", "list") + "\n")
	cfg, _ := f.gitRaw(f.repo, "config", "--get-regexp", `^branch\.`)
	b.WriteString("config:\n" + cfg)
	return f.normalize(b.String())
}

// stdio builds the command's Stdio over the box environment.
func (f *fx) stdio(cwd string, so, se *bytes.Buffer) cli.Stdio {
	return cli.Stdio{
		Out: so, Err: se, Cwd: cwd, Clock: time.Now,
		Env: func(k string) string {
			for i := len(f.env) - 1; i >= 0; i-- {
				if v, ok := strings.CutPrefix(f.env[i], k+"="); ok {
					return v
				}
			}
			return ""
		},
		Environ: func() []string { return append([]string(nil), f.env...) },
	}
}

// runGo runs the command on the box the way the shim does: RunCommand with --toolbelt first.
func runGo(t *testing.T, f *fx, c dcase) result {
	t.Helper()
	args, cwd := c.resolve(f)
	return f.runGoArgs(cwd, c.toolbelt(f), args)
}

func (f *fx) runGoArgs(cwd, toolbelt string, args []string) result {
	f.t.Helper()
	var so, se bytes.Buffer
	rc := RunCommand(append([]string{"--toolbelt", toolbelt}, args...), f.stdio(cwd, &so, &se))
	return f.collect(rc, so.String(), se.String())
}

func (f *fx) collect(rc int, stdout, stderr string) result {
	return result{RC: rc, Stdout: f.normalize(stdout), Stderr: f.normalize(stderr), State: f.state()}
}

const goldenPath = "testdata/golden/cases.json"

func readGoldens(t *testing.T) map[string]result {
	t.Helper()
	data, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("%v (regenerate with STAGE_UPDATE=1 go test -run TestDifferential)", err)
	}
	var m map[string]result
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("%s: %v", goldenPath, err)
	}
	return m
}

func diffResult(want, got result) string {
	var sb strings.Builder
	if want.RC != got.RC {
		sb.WriteString("exit: want " + quote(want.RC) + ", got " + quote(got.RC) + "\n")
	}
	for _, p := range []struct{ name, w, g string }{{"stdout", want.Stdout, got.Stdout}, {"stderr", want.Stderr, got.Stderr}, {"state", want.State, got.State}} {
		if p.w != p.g {
			sb.WriteString(p.name + ":\n  want " + quote(p.w) + "\n  got  " + quote(p.g) + "\n")
		}
	}
	return sb.String()
}

func quote(v any) string { b, _ := json.Marshal(v); return string(b) }
