package resume

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The scenario harness shared by the golden replay (runs everywhere, kills mutants without the oracle), the
// differential test (oracle_test.go: needs bash and the frozen scripts) and the unit tests. A scenario is a named
// world (a real git repository built once per process: the commands are read-only, and a test pins that), a PATH
// flavour, a working directory and an argv; both sides get the same environment and the same inputs.

var realPath = os.Getenv("PATH")

// baseTools is the PATH a "no X" scenario keeps: what the scripts need besides the tool under test.
const baseTools = "bash sh env cat date sed awk grep tr sort head mktemp rm timeout dirname basename wc uname"

// fixedNow is the clock of the Go side; every output that carries it is normalised on both sides.
var fixedNow = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

type world struct {
	root string // symlink-free
	repo string // root/r, the primary worktree
	// sha maps a revision name used by a scenario ({SHA:name}) to the commit it resolves to.
	sha map[string]string
}

var (
	worldMu    sync.Mutex
	worldsRoot string
	worlds     = map[string]*world{}
)

func TestMain(m *testing.M) {
	code := m.Run()
	if worldsRoot != "" {
		_ = os.RemoveAll(worldsRoot)
	}
	os.Exit(code)
}

// builder runs git with a fixed identity and a distinct fixed date per call, so shas repeat from run to run.
type builder struct {
	t    testing.TB
	root string
	n    int
}

func (b *builder) env() []string {
	b.n++
	d := fmt.Sprintf("2026-01-01T00:%02d:%02d +0000", b.n/60, b.n%60)
	return []string{"PATH=" + realPath, "HOME=" + filepath.Join(b.root, "home"), "GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_NOSYSTEM=1", "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t",
		"GIT_COMMITTER_EMAIL=t@t", "GIT_AUTHOR_DATE=" + d, "GIT_COMMITTER_DATE=" + d, "LC_ALL=C"}
}

func (b *builder) git(dir string, args ...string) string {
	b.t.Helper()
	c := exec.Command("git", append([]string{"-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"}, args...)...)
	c.Dir, c.Env = dir, b.env()
	out, err := c.CombinedOutput()
	if err != nil {
		b.t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
	return strings.TrimSpace(string(out))
}

func (b *builder) write(path, body string) {
	b.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		b.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		b.t.Fatal(err)
	}
}

func (b *builder) commit(dir, file, body string) {
	b.write(filepath.Join(dir, file), body)
	b.git(dir, "add", file)
	b.git(dir, "commit", "-q", "-m", "c "+file)
}

// getWorld returns the shared world of a kind, building it on first use.
func getWorld(t testing.TB, kind string) *world {
	t.Helper()
	worldMu.Lock()
	defer worldMu.Unlock()
	if w, ok := worlds[kind]; ok {
		return w
	}
	if worldsRoot == "" {
		d, err := os.MkdirTemp("", "resumeworlds")
		if err != nil {
			t.Fatal(err)
		}
		worldsRoot = d
	}
	root := filepath.Join(worldsRoot, kind)
	if err := os.MkdirAll(filepath.Join(root, "home"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tmp"), 0o755); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	w := &world{root: real, repo: filepath.Join(real, "r"), sha: map[string]string{}}
	b := &builder{t: t, root: real}
	buildKind(b, w, kind)
	stubs(t, w)
	worlds[kind] = w
	return w
}

func buildKind(b *builder, w *world, kind string) {
	r := w.repo
	switch kind {
	case "basic", "bulk":
		must0(b.t, os.MkdirAll(r, 0o755))
		b.git(r, "init", "-q", "-b", "main", ".")
		b.commit(r, "a", "a\n")
		b.commit(r, "sub/f", "f\n")
		b.git(w.root, "init", "-q", "--bare", "r.origin")
		b.git(r, "remote", "add", "origin", filepath.Join(w.root, "r.origin"))
		b.git(r, "push", "-q", "origin", "main")
		b.git(r, "fetch", "-q", "origin")
		wa := filepath.Join(w.root, "wt-a")
		b.git(r, "worktree", "add", "-q", "-b", "feat/a", wa, "main")
		b.commit(wa, "x", "x\n")
		b.commit(wa, "y", "y\n")
		b.write(filepath.Join(wa, "a"), "a\ndirty\n")
		b.write(filepath.Join(wa, "u1"), "1\n")
		b.write(filepath.Join(wa, "u2"), "2\n")
		b.commit(r, "m", "m\n")
		b.git(r, "push", "-q", "origin", "main")
		b.git(r, "branch", "loose", "main~1")
		b.git(r, "branch", "ahead1", "main")
		b.git(r, "checkout", "-q", "ahead1")
		b.commit(r, "z", "z\n")
		b.git(r, "checkout", "-q", "main")
		wd := filepath.Join(w.root, "wt-d")
		b.git(r, "worktree", "add", "-q", "--detach", wd, "main~1")
		b.write(filepath.Join(wd, "only-untracked"), "u\n")
		wp := filepath.Join(w.root, "wt-p")
		b.git(r, "worktree", "add", "-q", "-b", "feat/p", wp, "main")
		must0(b.t, os.RemoveAll(wp))
		wl := filepath.Join(w.root, "wt-l")
		b.git(r, "worktree", "add", "-q", "-b", "feat/l", wl, "main")
		b.git(r, "worktree", "lock", wl)
		b.git(r, "branch", "dup", "main")
		b.git(r, "tag", "dup", "main")
		// a branch whose name is not UTF-8 and a worktree whose path has a space and a non-ASCII letter
		b.git(r, "branch", "bad-\xff-name", "main")
		wu := filepath.Join(w.root, "wt sp é")
		b.git(r, "worktree", "add", "-q", "-b", "feat/u", wu, "main")
		b.write(filepath.Join(w.root, "plain", "x"), "x\n")
		if kind == "bulk" {
			for i := 1; i <= 60; i++ {
				b.git(r, "branch", fmt.Sprintf("bulk/%0120d", i), "main")
			}
		}
		for _, rev := range []string{"main", "main~1", "loose", "origin/main"} {
			w.sha[rev] = b.git(r, "rev-parse", rev)
		}
	case "plain":
		must0(b.t, os.MkdirAll(r, 0o755))
		b.git(r, "init", "-q", "-b", "main", ".")
		b.commit(r, "a", "a\n")
		b.write(filepath.Join(r, "u"), "u\n")
		w.sha["main"] = b.git(r, "rev-parse", "main")
	case "nobase":
		must0(b.t, os.MkdirAll(r, 0o755))
		b.git(r, "init", "-q", "-b", "trunk", ".")
		b.commit(r, "a", "a\n")
		w.sha["trunk"] = b.git(r, "rev-parse", "trunk")
	case "bare":
		b.git(w.root, "init", "-q", "--bare", "r")
	default:
		b.t.Fatalf("unknown world kind %q", kind)
	}
}

func must0(t testing.TB, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// ghStubs are the gh programs a scenario can put first on PATH. Every one answers `pr list ...`; rec also records
// the argv and the working directory it ran in.
var ghStubs = map[string]string{
	"ok":      `echo '[{"number":7,"headRefName":"feat/a","state":"OPEN","url":"https://x/7"},{"number":9,"headRefName":"feat/b","state":"OPEN","url":"https://x/9"}]'`,
	"empty":   `echo '[]'`,
	"bad":     "echo boom >&2\nexit 1",
	"junk":    `echo notjson`,
	"t124":    "echo late >&2\nexit 124",
	"full":    `jq -nc '[range(1000)|{number:.,headRefName:"b\(.)",state:"OPEN",url:"u"}]'`,
	"obj":     `echo '{"k":{"number":1,"headRefName":"x","state":"OPEN","url":"u"}}'`,
	"nullel":  `echo '[null]'`,
	"scalar":  `echo '[1]'`,
	"two":     `echo '[] []'`,
	"silent":  `exit 0`,
	"partial": `echo '[{"number":"7","headRefName":null,"state":"OPEN","extra":1},{}]'`,
	"scalar0": `echo '3'`,
	"rec":     "echo \"$@\" > \"$GH_REC\"\npwd >> \"$GH_REC\"\necho '[]'",
}

func stubs(t testing.TB, w *world) {
	t.Helper()
	for name, body := range ghStubs {
		p := filepath.Join(w.root, "stubs", name, "gh")
		must0(t, os.MkdirAll(filepath.Dir(p), 0o755))
		must0(t, os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o755))
	}
	// A git that logs, one line per call, the GIT_OPTIONAL_LOCKS it sees and its argv (fields separated by \x1f),
	// then runs the real one.
	real, err := exec.LookPath("git")
	must0(t, err)
	g := filepath.Join(w.root, "stubs", "gitlog", "git")
	must0(t, os.MkdirAll(filepath.Dir(g), 0o755))
	script := fmt.Sprintf("#!/bin/sh\n{ printf '%%s' \"${GIT_OPTIONAL_LOCKS-unset}\"; printf '\\037%%s' \"$@\"; echo; } >> \"%s\"\nexec \"%s\" \"$@\"\n", w.gitLog(), real)
	must0(t, os.WriteFile(g, []byte(script), 0o755))
}

func (w *world) gitLog() string { return filepath.Join(w.root, "gitlog.txt") }

// pathFor builds the PATH of a flavour: "real", "gh:<stub>", "nogh", "nojq", "nogit", "notimeout:<stub>", "gitlog".
func pathFor(t testing.TB, w *world, flavour string) string {
	t.Helper()
	tools := func(name string, list ...string) string {
		d := filepath.Join(w.root, "paths", name)
		if _, err := os.Stat(d); err == nil {
			return d
		}
		must0(t, os.MkdirAll(d, 0o755))
		for _, tool := range list {
			if p, err := exec.LookPath(tool); err == nil {
				must0(t, os.Symlink(p, filepath.Join(d, tool)))
			}
		}
		return d
	}
	base := strings.Fields(baseTools)
	// host is the host PATH behind a gh that fails as an unauthenticated gh does. The host's real gh is never run:
	// it writes its state (home/.local/state/gh/device-id) into the world and may reach the network.
	host := func() string {
		d := filepath.Join(w.root, "paths", "host-gh")
		if _, err := os.Stat(d); err != nil {
			must0(t, os.MkdirAll(d, 0o755))
			must0(t, os.WriteFile(filepath.Join(d, "gh"), []byte("#!/bin/sh\necho 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4\n"), 0o755))
		}
		return d + ":" + realPath
	}
	switch {
	case flavour == "" || flavour == "real":
		return host()
	case strings.HasPrefix(flavour, "gh:"):
		return filepath.Join(w.root, "stubs", strings.TrimPrefix(flavour, "gh:")) + ":" + realPath
	case flavour == "gitlog":
		return filepath.Join(w.root, "stubs", "gitlog") + ":" + host()
	case flavour == "noexec-gh":
		d := tools("noexec-gh", append([]string{"git", "jq"}, base...)...)
		must0(t, os.WriteFile(filepath.Join(d, "gh"), []byte("#!/bin/sh\necho '[]'\n"), 0o644))
		return d
	case flavour == "nogh":
		return tools("nogh", append([]string{"git", "jq"}, base...)...)
	case flavour == "nojq":
		return tools("nojq", append([]string{"git"}, base...)...)
	case flavour == "nogit":
		return tools("nogit", append([]string{"jq"}, base...)...)
	case strings.HasPrefix(flavour, "notimeout:"):
		var keep []string
		for _, b := range base {
			if b != "timeout" {
				keep = append(keep, b)
			}
		}
		name := "notimeout-" + strings.TrimPrefix(flavour, "notimeout:")
		d := tools(name, append([]string{"git", "jq"}, keep...)...)
		src, err := os.ReadFile(filepath.Join(w.root, "stubs", strings.TrimPrefix(flavour, "notimeout:"), "gh"))
		must0(t, err)
		must0(t, os.WriteFile(filepath.Join(d, "gh"), src, 0o755))
		return d
	}
	t.Fatalf("unknown PATH flavour %q", flavour)
	return ""
}

// scn is one invocation.
type scn struct {
	name   string
	cmd    string // resume-state | resume-render
	world  string // default basic
	path   string // PATH flavour, default real
	args   []string
	env    map[string]string
	stdin  string
	files  map[string]string // written under <root>/in before the run
	cwd    string            // relative to the world root; default r
	toolbl bool              // differential only: also run the Go render with --toolbelt <frozen dir>
}

type outcome struct {
	rc       int
	out, err string
}

func (sc scn) world0() string {
	if sc.world == "" {
		return "basic"
	}
	return sc.world
}

// expand replaces the placeholders of an argument: {R} the primary worktree, {ROOT} the world root, {IN} the input
// directory, {SHA:rev} a commit of the world.
var shaRe = regexp.MustCompile(`\{SHA:([^}]+)\}`)

func (sc scn) argv(w *world) []string {
	out := make([]string, len(sc.args))
	for i, a := range sc.args {
		a = strings.ReplaceAll(a, "{R}", w.repo)
		a = strings.ReplaceAll(a, "{ROOT}", w.root)
		a = strings.ReplaceAll(a, "{IN}", filepath.Join(w.root, "in"))
		a = shaRe.ReplaceAllStringFunc(a, func(m string) string { return w.sha[shaRe.FindStringSubmatch(m)[1]] })
		out[i] = a
	}
	return out
}

func (sc scn) environ(t testing.TB, w *world) []string {
	m := map[string]string{"PATH": pathFor(t, w, sc.path), "HOME": filepath.Join(w.root, "home"),
		"TMPDIR": filepath.Join(w.root, "tmp"), "LC_ALL": "C", "GH_REC": filepath.Join(w.root, "gh-rec.txt")}
	for k, v := range sc.env {
		m[k] = strings.ReplaceAll(v, "{ROOT}", w.root)
	}
	var out []string
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

func (sc scn) prepare(t testing.TB, w *world) string {
	t.Helper()
	for p, body := range sc.files {
		full := filepath.Join(w.root, "in", p)
		must0(t, os.MkdirAll(filepath.Dir(full), 0o755))
		must0(t, os.WriteFile(full, []byte(body), 0o644))
	}
	cwd := w.repo
	if sc.cwd != "" {
		cwd = filepath.Join(w.root, sc.cwd)
	}
	return cwd
}

func commandTable() []cli.Command { return []cli.Command{StateCommand, RenderCommand} }

func runGo(t testing.TB, sc scn, extra ...string) outcome {
	t.Helper()
	w := getWorld(t, sc.world0())
	cwd := sc.prepare(t, w)
	environ := sc.environ(t, w)
	return runGoIn(sc, w, cwd, environ, extra...)
}

func runGoIn(sc scn, w *world, cwd string, environ []string, extra ...string) outcome {
	var out, errb bytes.Buffer
	lookup := func(k string) string {
		for i := len(environ) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(environ[i], k+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader(sc.stdin), Out: &out, Err: &errb, Env: lookup,
		Environ: func() []string { return append([]string(nil), environ...) },
		Clock:   func() time.Time { return fixedNow }, Cwd: cwd}
	args := append([]string{"status", sc.cmd}, extra...)
	args = append(args, sc.argv(w)...)
	rc := cli.Run(commandTable(), args, s)
	return outcome{rc, out.String(), errb.String()}
}

var (
	genRe  = regexp.MustCompile(`"generated_at": "[^"]*"`)
	prosRe = regexp.MustCompile(`Generated [^ ]+ ·`)
)

// normalise scrubs what differs between two runs of the same scenario: the world root and, for the outputs that
// carry the wall clock, the generation time.
func normalise(sc scn, w *world, s string) string {
	s = strings.ReplaceAll(s, w.root, "@ROOT@")
	if sc.cmd == "resume-state" || !hasArg(sc.args, "--json") {
		s = genRe.ReplaceAllString(s, `"generated_at": "@T@"`)
		s = strings.ReplaceAll(s, `"generated_at":"`+fixedNow.Format("2006-01-02T15:04:05Z")+`"`, `"generated_at":"@T@"`)
		s = prosRe.ReplaceAllString(s, "Generated @T@ ·")
	}
	return s
}

func hasArg(args []string, a string) bool {
	for _, x := range args {
		if x == a {
			return true
		}
	}
	return false
}

// goldenText is the golden form of one outcome.
func goldenText(o outcome) string {
	return fmt.Sprintf("rc: %d\n--- stdout\n%s--- stderr\n%s", o.rc, nl(o.out), nl(o.err))
}

func nl(s string) string {
	if s != "" && !strings.HasSuffix(s, "\n") {
		return s + "\n"
	}
	return s
}
