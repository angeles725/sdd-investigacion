//go:build unix

package console

// The world of one scenario: a private directory holding the cwd of the run, the target directories and a PATH
// made only of symlinks to the few real tools the legacy script needs plus the stubs a scenario writes. The real
// powershell.exe of a WSL host is never reachable, and no external tool is ever run for real.

import (
	"bytes"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// realTools are what the frozen script runs besides bash builtins.
var realTools = []string{"date", "mkdir", "tee", "cat"}

type world struct {
	t   *testing.T
	dir string // the cwd of the run; every relative path is relative to it
	bin string // the PATH of the run
}

func newWorld(t *testing.T) *world {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, dir: dir, bin: dir + "/bin"}
	w.mkdir("bin", 0o755)
	for _, tool := range realTools {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Fatalf("the differential needs %s: %v", tool, err)
		}
		if err := os.Symlink(p, w.bin+"/"+tool); err != nil {
			t.Fatal(err)
		}
	}
	return w
}

func (w *world) must(err error) {
	w.t.Helper()
	if err != nil {
		w.t.Fatal(err)
	}
}

// sub replaces the <W> placeholder of a scenario string with this world's directory.
func (w *world) sub(s string) string { return strings.ReplaceAll(s, "<W>", w.dir) }

func (w *world) subAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = w.sub(s)
	}
	return out
}

func (w *world) mkdir(rel string, mode os.FileMode) {
	w.t.Helper()
	w.must(os.MkdirAll(w.dir+"/"+rel, 0o755))
	w.must(os.Chmod(w.dir+"/"+rel, mode))
}

func (w *world) file(rel, content string, mode os.FileMode) {
	w.t.Helper()
	w.must(os.MkdirAll(filepath.Dir(w.dir+"/"+rel), 0o755))
	w.must(os.WriteFile(w.dir+"/"+rel, []byte(content), mode))
	w.must(os.Chmod(w.dir+"/"+rel, mode))
}

// stub writes an executable shell stub into the PATH. Bodies use shell builtins only.
func (w *world) stub(name, body string) { w.file("bin/"+name, "#!/bin/sh\n"+body+"\n", 0o755) }

func (w *world) symlink(target, rel string) {
	w.t.Helper()
	w.must(os.Symlink(w.sub(target), w.dir+"/"+rel))
}

// environ is the whole environment of a run: the private PATH, the C locale, then the scenario's own entries.
func (w *world) environ(extra []string) []string {
	return append([]string{"PATH=" + w.bin, "LC_ALL=C", "HOME=" + w.dir}, w.subAll(extra)...)
}

// ran is what one run produced; Tree is the file tree it left behind.
type ran struct {
	Out, Err string
	RC       int
	Tree     string
}

func lookup(env []string) func(string) string {
	return func(k string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, k+"="); ok {
				v = s
			}
		}
		return v
	}
}

// goRun runs the Go command in process in this world.
func (w *world) goRun(sc *scenario) ran {
	w.t.Helper()
	env := w.environ(sc.env)
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(sc.stdin), Out: &o, Err: &e, Env: lookup(env),
		Environ: func() []string { return env }, Clock: time.Now, Cwd: w.dir}
	rc := Run(w.subAll(sc.args), s)
	return ran{o.String(), e.String(), rc, w.tree()}
}

var (
	reTS = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)
	// reExecPrefix is what bash puts before the message of a command it cannot execute: the script path and line.
	reExecPrefix = regexp.MustCompile(`\S*serial-console\.sh: line [0-9]+: `)
	// reKilled is bash's job notice for a child killed by a signal: script path, line, the child's pid and its command.
	reKilled = regexp.MustCompile(`(?m)^\S*serial-console\.sh: line [0-9]+: [0-9]+ [A-Z][^\n]*\n`)
)

// norm makes a result comparable across two worlds: the world directory and the timestamps are placeholders. For the
// legacy side it also removes the two bash-only decorations a scenario declares (see scenario).
func (w *world) norm(r ran, sc *scenario, legacy bool) ran {
	f := func(s string) string {
		if legacy && sc.legacyKilled {
			s = reKilled.ReplaceAllString(s, "")
		}
		if legacy && sc.legacyExec {
			s = reExecPrefix.ReplaceAllString(s, "serial-console.sh: ")
		}
		return reTS.ReplaceAllString(strings.ReplaceAll(s, w.dir, "<W>"), "<TS>")
	}
	return ran{f(r.Out), f(r.Err), r.RC, f(r.Tree)}
}

// tree lists everything under the world except the PATH: path, mode, and the content of a regular file.
func (w *world) tree() string {
	var lines []string
	err := filepath.WalkDir(w.dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(w.dir, p)
		if rel == "." || rel == "bin" {
			if rel == "bin" {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			dst, _ := os.Readlink(p)
			lines = append(lines, "l "+rel+" -> "+dst)
		case info.IsDir():
			lines = append(lines, "d "+rel+" "+info.Mode().Perm().String())
		default:
			b, _ := os.ReadFile(p)
			lines = append(lines, "f "+rel+" "+info.Mode().Perm().String()+"\n"+string(b)+"\n--")
		}
		return nil
	})
	w.must(err)
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}
