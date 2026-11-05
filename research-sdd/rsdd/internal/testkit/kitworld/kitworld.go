// Package kitworld builds the hermetic worlds of the kit-maintenance tool tests (kit issue #2212): one case directory
// holding a PATH made only of symlinks, the recording shim (toolbelt/tests/fixtures/kit-pr-pipeline/shim.sh) as git,
// gh, gentle-ai and flock plus the few real tools a tool needs. It is the Go twin of fixtures/kit-pr-pipeline/harness.sh,
// so a Go test and a bash suite script the very same calls the very same way, and a legacy-vs-Go differential runs
// both sides in an identical world.
package kitworld

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// FixDir is the fixture directory (shim.sh, harness.sh and the canned outputs) below the research-sdd directory.
const FixDir = "toolbelt/tests/fixtures/kit-pr-pipeline"

// realTools are linked into a world's PATH next to the shims.
var realTools = []string{"bash", "env", "cat", "grep", "sed", "awk", "sleep", "date", "mkdir", "rm", "cut", "tail", "head",
	"dirname", "readlink", "basename", "mktemp", "tr", "sort", "wc", "seq", "touch", "ls", "uniq", "tee", "ln", "find",
	"python3", "cp", "mv", "chmod", "true", "false", "sh"}

// shimmed are the tools the recording shim impersonates.
var shimmed = []string{"git", "gh", "gentle-ai", "flock"}

// World is one case.
type World struct {
	T                   *testing.T
	Dir, Bin, Wt, State string // case dir, PATH dir, worktree, shim state dir
	Fix                 string // the fixture directory (SHIM_FIX)
}

// New creates a case under a short fixed root (the temp path appears in some golden text; GOTMPDIR moves t.TempDir).
func New(t *testing.T) *World {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "kw")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	fix := kitroot.Path(t, filepath.FromSlash(FixDir))
	w := &World{T: t, Dir: root, Bin: root + "/bin", Wt: root + "/wt", State: root + "/state", Fix: fix}
	for _, d := range []string{w.Bin, w.Wt, w.State} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, tool := range shimmed {
		if err := os.Symlink(filepath.Join(fix, "shim.sh"), filepath.Join(w.Bin, tool)); err != nil {
			t.Fatal(err)
		}
	}
	for _, tool := range realTools {
		if p, err := lookPath(tool); err == nil {
			_ = os.Symlink(p, filepath.Join(w.Bin, tool))
		}
	}
	for _, f := range []string{"calls.log", "rules.tsv"} {
		if err := os.WriteFile(filepath.Join(w.State, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return w
}

func lookPath(tool string) (string, error) {
	for _, d := range filepath.SplitList("/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin") {
		p := filepath.Join(d, tool)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", os.ErrNotExist
}

// Rule appends a shim rule: the first rule whose tool and argument glob match and whose times budget is not spent
// wins. out is a fixture file name ("" for none), times 0 is unlimited, opt is "" or `barrier=NAME:N`.
func (w *World) Rule(tool, glob string, rc int, out string, times int, opt string) {
	o, tm, op := out, fmt.Sprint(times), opt
	if o == "" {
		o = "-"
	}
	if times == 0 {
		tm = "-"
	}
	if op == "" {
		op = "-"
	}
	line := strings.Join([]string{tool, glob, fmt.Sprint(rc), o, tm, op}, "\t") + "\n"
	f, err := os.OpenFile(filepath.Join(w.State, "rules.tsv"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		w.T.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(line); err != nil {
		w.T.Fatal(err)
	}
}

// Drop removes a tool from the PATH (a missing dependency).
func (w *World) Drop(tool string) {
	if err := os.Remove(filepath.Join(w.Bin, tool)); err != nil {
		w.T.Fatal(err)
	}
}

// Calls is the recorded call log.
func (w *World) Calls() string {
	b, err := os.ReadFile(filepath.Join(w.State, "calls.log"))
	if err != nil {
		w.T.Fatal(err)
	}
	return string(b)
}

// Env is the child environment of a run in this world: PATH of symlinks only, a private HOME, the shim state and
// whatever the case adds (later entries win, as exec reads them).
func (w *World) Env(extra ...string) []string {
	env := []string{"PATH=" + w.Bin, "HOME=" + w.Dir, "SHIM_STATE=" + w.State, "SHIM_FIX=" + w.Fix,
		"GIT_CONFIG_NOSYSTEM=1", "KIT_RETRY_SLEEP=0", "KIT_POLL_SLEEP=0", "KIT_MERGE_SLEEP=0"}
	return append(env, extra...)
}

// Fixture is the content of a canned output file.
func (w *World) Fixture(name string) string {
	b, err := os.ReadFile(filepath.Join(w.Fix, name))
	if err != nil {
		w.T.Fatalf("fixture %s: %v", name, err)
	}
	return string(b)
}

// Norm replaces the case directory by <W> so two runs in different worlds compare equal.
func (w *World) Norm(s string) string { return strings.ReplaceAll(s, w.Dir, "<W>") }
