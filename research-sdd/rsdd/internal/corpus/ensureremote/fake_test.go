package ensureremote

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// world is a hermetic stand-in for git, bash (the secret scanner) and gh: no process starts, no network is
// reachable, and every call is logged in order. The target directory is a real temp dir, because the command
// reads and writes its .gitignore and its allow list there itself.
type world struct {
	t        *testing.T
	root     string
	target   string
	toolbelt string
	env      map[string]string

	calls          []string // every external call: git/bash argv, "gh <args>" and "probe <repo>"
	cmds           []Cmd    // the Cmd of every run, for env/timeout assertions
	ghops          []ghCall // the Options of every gh call
	stdout, stderr bytes.Buffer

	// git
	notRepo     bool
	origin      string // the configured origin URL ("" = none)
	originEmpty bool   // `remote get-url origin` succeeds with empty output
	removeFail  bool
	diffRC      int
	untracked   string
	commitRC    int
	addRC       int
	addErr      string
	statusFail  bool
	statusOut   string
	lsFilesFail bool
	pushRC      int
	pushOut     string
	pushErr     string
	tracked     []string
	history     map[string][]string // path -> raw lines
	logFail     map[string]bool
	blobs       map[string][]byte
	catFail     map[string]bool
	nblob       int

	// scanner
	scanRC  int
	scanErr error

	// gh
	noGH         bool
	owner        string
	ownerFail    bool
	ownerType    string
	ownerTypeRC  int
	createState  gh.State
	createRC     int
	createOut    string
	createErr    string
	createBound  gh.Bound
	createAdds   bool // a create adds the local origin, as `--source --remote origin` does
	editState    gh.State
	editRC       int
	editBound    gh.Bound
	vis          []gh.Visibility // successive probe answers; the last one repeats
	visAfterEdit *gh.Visibility
	probes       int
	edited       bool
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root := t.TempDir()
	w := &world{
		t: t, root: root, target: filepath.Join(root, "target"), toolbelt: filepath.Join(root, "toolbelt"),
		env:     map[string]string{"HOME": "/home/x", "PATH": "/fake/bin"},
		history: map[string][]string{}, logFail: map[string]bool{}, blobs: map[string][]byte{}, catFail: map[string]bool{},
		owner: "tester", ownerType: "User", createState: gh.StateOK, editState: gh.StateOK,
		createBound: gh.Bound{Seconds: 60}, editBound: gh.Bound{Seconds: 20},
		vis: []gh.Visibility{{State: gh.StatePrivate, Bound: gh.Bound{Seconds: 20}}},
	}
	for _, d := range []string{w.target, w.toolbelt} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(w.toolbelt, "scan-secrets.sh"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return w
}

func (w *world) stdio() cli.Stdio {
	environ := func() []string {
		var out []string
		for k, v := range w.env {
			out = append(out, k+"="+v)
		}
		return out
	}
	return cli.Stdio{
		Out: &w.stdout, Err: &w.stderr, Cwd: w.root,
		Env:     func(k string) string { return w.env[k] },
		Environ: environ,
		Clock:   func() time.Time { return time.Unix(0, 0) },
	}
}

func (w *world) deps() deps {
	return deps{
		run:     w.run,
		gh:      GH{Run: w.ghRun, Probe: w.ghProbe},
		hasTool: func(name string, _ []string) bool { return name != "gh" || !w.noGH },
	}
}

// exec runs the command with --toolbelt (as the shim passes it) unless the args already name one.
func (w *world) exec(args ...string) int {
	w.t.Helper()
	if !contains(args, "--toolbelt") {
		args = append([]string{"--toolbelt", w.toolbelt}, args...)
	}
	return execute(args, w.stdio(), w.deps())
}

// ok runs the command on the target with consent and returns the exit code.
func (w *world) ok(extra ...string) int {
	w.t.Helper()
	return w.exec(append([]string{w.target, "--yes"}, extra...)...)
}

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

func (w *world) called(sub string) bool {
	for _, c := range w.calls {
		if strings.Contains(c, sub) {
			return true
		}
	}
	return false
}

func (w *world) count(sub string) int {
	n := 0
	for _, c := range w.calls {
		if strings.Contains(c, sub) {
			n++
		}
	}
	return n
}

func (w *world) pushed() bool  { return w.called(" push ") }
func (w *world) created() bool { return w.called("gh repo create") }
func (w *world) out() string   { return w.stdout.String() }
func (w *world) err() string   { return w.stderr.String() }

func (w *world) allOut() string { return w.out() + w.err() }

// track registers a tracked secret-type path and, with kinds, its committed history (oldest first).
func (w *world) track(path string, kinds ...string) {
	w.tracked = append(w.tracked, path)
	for _, k := range kinds {
		w.commit(path, fixture(w.t, k))
	}
}

// commit adds one revision of path whose new blob is b (the old side is the previous revision, or all zeros).
func (w *world) commit(path string, b []byte) {
	old := strings.Repeat("0", 40)
	if l := w.history[path]; len(l) > 0 {
		f := strings.Fields(l[len(l)-1])
		old = f[3]
	}
	w.rawLine(path, old, w.blob(b))
}

func (w *world) blob(b []byte) string {
	w.nblob++
	id := fmt.Sprintf("%040x", w.nblob)
	w.blobs[id] = b
	return id
}

func (w *world) rawLine(path, oldID, newID string) {
	w.history[path] = append(w.history[path], fmt.Sprintf(":100644 100644 %s %s M\t%s", oldID, newID, path))
}

func (w *world) conf(lines ...string) {
	w.t.Helper()
	dir := filepath.Join(w.target, ".research-sdd")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "secret-files.conf"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// run is the Runner: it answers like git and bash would for the scripted repository.
func (w *world) run(c Cmd) Out {
	w.cmds = append(w.cmds, c)
	w.calls = append(w.calls, strings.Join(c.Argv, " "))
	a := c.Argv
	if a[0] == "bash" {
		return Out{RC: w.scanRC, Err: w.scanErr}
	}
	a = a[1:]
	if len(a) > 0 && a[0] == "--literal-pathspecs" {
		a = a[1:]
	}
	if len(a) < 3 || a[0] != "-C" {
		w.t.Fatalf("unexpected git argv %v", c.Argv)
	}
	a = a[2:]
	fail := func(rc int) Out { return Out{RC: rc, Stderr: []byte("fatal: scripted failure\n")} }
	switch a[0] {
	case "rev-parse":
		if w.notRepo {
			return fail(128)
		}
	case "remote":
		switch a[1] {
		case "get-url":
			if w.origin == "" && !w.originEmpty {
				return fail(2)
			}
			return Out{Stdout: []byte(w.origin + "\n")}
		case "remove":
			if w.removeFail {
				return fail(1)
			}
			w.origin = ""
		}
	case "diff":
		return Out{RC: w.diffRC}
	case "ls-files":
		if a[1] == "--others" {
			return Out{Stdout: []byte(w.untracked)}
		}
		if w.lsFilesFail {
			return fail(128)
		}
		var sb strings.Builder
		for _, p := range w.tracked {
			sb.WriteString(p + "\x00")
		}
		return Out{Stdout: []byte(sb.String())}
	case "add":
		return Out{RC: w.addRC, Stderr: []byte(w.addErr)}
	case "commit":
		return Out{RC: w.commitRC}
	case "status":
		if w.statusFail {
			return fail(128)
		}
		return Out{Stdout: []byte(w.statusOut)}
	case "log":
		p := a[len(a)-1]
		if w.logFail[p] {
			return fail(128)
		}
		if l := w.history[p]; len(l) > 0 {
			return Out{Stdout: []byte(strings.Join(l, "\n") + "\n")}
		}
		return Out{}
	case "cat-file":
		id := a[2]
		if b, ok := w.blobs[id]; ok && !w.catFail[id] {
			return Out{Stdout: b}
		}
		return fail(128)
	case "push":
		return Out{RC: w.pushRC, Stdout: []byte(w.pushOut), Stderr: []byte(w.pushErr)}
	}
	return Out{}
}

func (w *world) ghRun(o gh.Options, args ...string) (gh.RunResult, error) {
	w.ghops = append(w.ghops, ghCall{"gh " + strings.Join(args, " "), o})
	w.calls = append(w.calls, "gh "+strings.Join(args, " "))
	switch {
	case args[0] == "api" && args[1] == "user":
		if w.ownerFail {
			return gh.RunResult{State: gh.StateError, RC: 1}, nil
		}
		return gh.RunResult{State: gh.StateOK, Stdout: []byte(w.owner + "\n")}, nil
	case args[0] == "api":
		if w.ownerTypeRC != 0 {
			return gh.RunResult{State: gh.StateError, RC: w.ownerTypeRC, Stdout: []byte(w.ownerType + "\n")}, nil
		}
		return gh.RunResult{State: gh.StateOK, Stdout: []byte(w.ownerType + "\n")}, nil
	case args[0] == "repo" && args[1] == "create":
		if w.createAdds {
			w.origin = "https://github.com/" + w.owner + "/research-target.git"
		}
		return gh.RunResult{State: w.createState, RC: w.createRC, Bound: w.createBound, Stdout: []byte(w.createOut), Stderr: []byte(w.createErr)}, nil
	case args[0] == "repo" && args[1] == "edit":
		w.edited = true
		return gh.RunResult{State: w.editState, RC: w.editRC, Bound: w.editBound}, nil
	}
	w.t.Fatalf("unexpected gh call %v", args)
	return gh.RunResult{}, nil
}

func (w *world) ghProbe(o gh.Options, repo string) (gh.Visibility, error) {
	w.ghops = append(w.ghops, ghCall{"probe " + repo, o})
	w.calls = append(w.calls, "probe "+repo)
	if w.edited && w.visAfterEdit != nil {
		return *w.visAfterEdit, nil
	}
	i := min(w.probes, len(w.vis)-1)
	w.probes++
	return w.vis[i], nil
}

func visOf(s gh.State) gh.Visibility { return gh.Visibility{State: s, Bound: gh.Bound{Seconds: 20}} }

type ghCall struct {
	line string
	o    gh.Options
}

// optsOf returns the Options of the first gh call whose line starts with prefix.
func (w *world) optsOf(prefix string) gh.Options {
	w.t.Helper()
	for _, c := range w.ghops {
		if strings.HasPrefix(c.line, prefix) {
			return c.o
		}
	}
	w.t.Fatalf("no gh call %q in %v", prefix, w.calls)
	return gh.Options{}
}
