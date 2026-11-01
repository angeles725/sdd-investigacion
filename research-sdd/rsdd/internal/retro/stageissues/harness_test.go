package stageissues

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// This file is the shared test harness. It carries no build tag: gremlins builds with -tags nodiff and the unit
// and golden tests below need it. The tagged file differential_test.go adds the live legacy run on top.
//
// A case is run in a BOX: a temp dir that looks like a kit checkout (research-sdd/toolbelt with the frozen legacy
// script and libs, research-sdd/TARGETS.md with one registered target, rh/target-foo/retros/ for the retro, bin/gh
// = the fake gh of testdata/gh-stub.sh). The legacy run and the Go run use the SAME box and retro path (so paths
// in messages are equal) and each its own STUB_DIR (call log + state). Box paths are replaced by @BOX@ in every
// recorded output so goldens do not depend on the temp dir.

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): STAGEISSUES_UPDATE=1 make test
// TESTFLAGS='-run TestDifferential'. An environment variable, not a flag: make test runs every package, and a
// flag only this package defines would fail the others.
func updateGoldens() bool { return os.Getenv("STAGEISSUES_UPDATE") == "1" }

// dcase is one scenario.
type dcase struct {
	name string
	// retro is the content of rh/target-foo/retros/r.md; noRetro leaves it absent.
	retro   string
	noRetro bool
	// fixture names a file of fixtureDir used as the retro (fixturePrefix is prepended, e.g. a marker line).
	fixture, fixturePrefix string
	// files are extra files relative to the box root.
	files map[string]string
	// args follow the retro path; raw replaces the whole argument list (the retro path is then literal).
	args []string
	raw  []string
	// env is added to the base environment of both runs.
	env map[string]string
	// stub seeds the fake gh's STUB_DIR (state files) and runs once per side.
	stub func(dir string)
	// prep runs once on the box after it is built (git init, TARGETS variants, symlinks).
	prep func(t *testing.T, b *box)
	// path selects the PATH: "" = box/bin + the real PATH; "nogh" = tools only, no gh; "nogit" = box/bin + tools, no git.
	path string
	// locale is LC_ALL for both runs; "" means C.
	locale string
	// cwd is relative to the box root; "" means work/.
	cwd string
}

type box struct {
	root   string
	retro  string
	toolbt string
}

// result is what one run produced, normalised.
type result struct {
	RC     int               `json:"rc"`
	Stdout string            `json:"stdout"`
	Stderr string            `json:"stderr"`
	GHLog  string            `json:"ghlog"`
	State  map[string]string `json:"state,omitempty"`
}

const defaultTargets = "# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `@BOX@/rh/target-foo` |\n"

func mkBox(t *testing.T, c dcase) *box {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	b := &box{root: root, toolbt: filepath.Join(root, "research-sdd", "toolbelt")}
	for _, d := range []string{"research-sdd/toolbelt/lib", "rh/target-foo/retros", "bin", "work"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	copyFile(t, "testdata/legacy/stage-retro-issues.sh", filepath.Join(b.toolbt, "stage-retro-issues.sh"), 0o755)
	for _, l := range []string{"retro-status", "retro-grammar", "scrub-issue-text", "target-paths"} {
		copyFile(t, "testdata/legacy/lib/"+l+".sh", filepath.Join(b.toolbt, "lib", l+".sh"), 0o644)
	}
	copyFile(t, "testdata/gh-stub.sh", filepath.Join(root, "bin", "gh"), 0o755)
	write(t, filepath.Join(root, "research-sdd", "TARGETS.md"), strings.ReplaceAll(defaultTargets, "@BOX@", root))
	b.retro = filepath.Join(root, "rh", "target-foo", "retros", "r.md")
	if c.fixture != "" {
		c.retro = c.fixturePrefix + fixture(t, c.fixture)
	}
	if !c.noRetro {
		write(t, b.retro, c.retro)
	}
	for name, content := range c.files {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		write(t, p, strings.ReplaceAll(content, "@BOX@", root))
	}
	if c.prep != nil {
		c.prep(t, b)
	}
	return b
}

func copyFile(t *testing.T, src, dst string, mode os.FileMode) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		t.Fatal(err)
	}
}

func write(t *testing.T, p, content string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// toolDirs are the system tools the legacy script needs, symlinked into a hermetic PATH dir.
var toolNames = []string{"awk", "grep", "sed", "tr", "dirname", "basename", "head", "tail", "sort", "uniq", "cut", "wc",
	"cksum", "find", "iconv", "cat", "env", "bash", "sh", "mktemp", "rm", "ls", "readlink", "date", "mkdir", "cp", "printf", "id", "tee"}

func hermeticPath(t *testing.T, b *box, withGh, withGit bool) string {
	t.Helper()
	dir := filepath.Join(b.root, "hbin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	names := append([]string{}, toolNames...)
	if withGit {
		names = append(names, "git")
	}
	for _, n := range names {
		p, err := exec.LookPath(n)
		if err != nil {
			continue
		}
		_ = os.Symlink(p, filepath.Join(dir, n))
	}
	if withGh {
		_ = os.Symlink(filepath.Join(b.root, "bin", "gh"), filepath.Join(dir, "gh"))
	}
	return dir
}

// envFor builds the whole environment of one run.
func envFor(t *testing.T, b *box, c dcase, stubDir string) []string {
	t.Helper()
	path := filepath.Join(b.root, "bin") + ":" + os.Getenv("PATH")
	switch c.path {
	case "nogh":
		path = hermeticPath(t, b, false, true)
	case "nogit":
		path = hermeticPath(t, b, true, false)
	}
	loc := c.locale
	if loc == "" {
		loc = "C"
	}
	env := map[string]string{
		"PATH": path, "LC_ALL": loc, "HOME": b.root, "STUB_DIR": stubDir,
		"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
		"RESEARCH_SDD_ISSUE_REPO": "test-owner/test-kit",
	}
	for k, v := range c.env {
		if v == "\x00unset" {
			delete(env, k)
			continue
		}
		env[k] = strings.ReplaceAll(v, "@BOX@", b.root)
	}
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

func (c dcase) argList(b *box) []string {
	if c.raw != nil {
		out := make([]string, len(c.raw))
		for i, a := range c.raw {
			out[i] = strings.ReplaceAll(a, "@BOX@", b.root)
		}
		return out
	}
	return append([]string{b.retro}, c.args...)
}

func (c dcase) workDir(b *box) string {
	if c.cwd != "" {
		return filepath.Join(b.root, c.cwd)
	}
	return filepath.Join(b.root, "work")
}

func envLookup(env []string) func(string) string {
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	return func(k string) string { return m[k] }
}

// runGo runs the Go command in-process through cli.Run, the way the rsdd binary dispatches it.
func runGo(t *testing.T, b *box, c dcase) result {
	t.Helper()
	stub := filepath.Join(b.root, "stub-go")
	seedStub(t, stub, c)
	env := envFor(t, b, c, stub)
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: envLookup(env), Environ: func() []string { return append([]string(nil), env...) },
		Clock: func() time.Time { return time.Unix(0, 0).UTC() }, Cwd: c.workDir(b),
	}
	args := append([]string{"retro", "stage-issues", "--toolbelt", b.toolbt}, c.argList(b)...)
	rc := cli.Run([]cli.Command{Command}, args, s)
	return collect(b, stub, rc, out.String(), errb.String())
}

func seedStub(t *testing.T, dir string, c dcase) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if c.stub != nil {
		c.stub(dir)
	}
}

func collect(b *box, stub string, rc int, stdout, stderr string) result {
	norm := func(s string) string { return strings.ReplaceAll(s, b.root, "@BOX@") }
	r := result{RC: rc, Stdout: norm(stdout), Stderr: norm(stderr)}
	if log, err := os.ReadFile(filepath.Join(stub, "gh.log")); err == nil {
		r.GHLog = norm(string(log))
	}
	entries, _ := os.ReadDir(stub)
	for _, e := range entries {
		if e.IsDir() || e.Name() == "gh.log" {
			continue
		}
		data, _ := os.ReadFile(filepath.Join(stub, e.Name()))
		if r.State == nil {
			r.State = map[string]string{}
		}
		r.State[e.Name()] = norm(string(data))
	}
	return r
}

func goldenPath(name string) string {
	return filepath.Join("testdata", "golden", strings.ReplaceAll(name, "/", "_")+".json")
}

func readGolden(t *testing.T, name string) result {
	t.Helper()
	data, err := os.ReadFile(goldenPath(name))
	if err != nil {
		t.Fatalf("no golden for %q (%v): run STAGEISSUES_UPDATE=1 make test TESTFLAGS='-run TestDifferential' with bash available", name, err)
	}
	var r result
	if err := json.Unmarshal(data, &r); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	return r
}

func diffResult(a, b result) string {
	var parts []string
	if a.RC != b.RC {
		parts = append(parts, fmt.Sprintf("rc: %d vs %d", a.RC, b.RC))
	}
	for _, f := range []struct{ n, x, y string }{{"stdout", a.Stdout, b.Stdout}, {"stderr", a.Stderr, b.Stderr}, {"ghlog", a.GHLog, b.GHLog}} {
		if f.x != f.y {
			parts = append(parts, fmt.Sprintf("%s differs:\n--- want\n%s\n--- got\n%s", f.n, f.x, f.y))
		}
	}
	names := map[string]bool{}
	for k := range a.State {
		names[k] = true
	}
	for k := range b.State {
		names[k] = true
	}
	var ks []string
	for k := range names {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	for _, k := range ks {
		if a.State[k] != b.State[k] {
			parts = append(parts, fmt.Sprintf("state %s differs: %q vs %q", k, a.State[k], b.State[k]))
		}
	}
	return strings.Join(parts, "\n")
}
