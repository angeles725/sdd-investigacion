package fetchdoc

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// systemTools are the real programs the legacy script and the curl/wget stubs need on their PATH. curl, wget,
// pandoc, pdftoppm and tesseract are NOT here: a scenario chooses which of them (as stubs) exist.
var systemTools = []string{"bash", "env", "mktemp", "awk", "sed", "cut", "date", "basename", "dirname", "rm", "mv", "ln", "cat",
	"grep", "file", "sha256sum", "mkdir", "sort", "tr", "head", "sleep", "cp", "kill", "printf", "wc", "touch", "chmod", "ls", "readlink"}

// fixedNow is the clock of the Go side; dates are normalised to <DATE> on both sides anyway.
var fixedNow = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

// world is one hermetic run: a private PATH holding chosen stubs, a private TMPDIR and a target directory.
type world struct {
	t                   *testing.T
	root, bin, tmp, dir string
	extraEnv            []string
	hash                func(string) (string, error) // nil: the real sha256
}

// newWorld builds a world whose PATH has the system tools plus the named stubs (see installStub).
func newWorld(t *testing.T, stubs ...string) *world {
	t.Helper()
	root := t.TempDir()
	w := &world{t: t, root: root, bin: root + "/bin", tmp: root + "/tmp", dir: root + "/target"}
	for _, d := range []string{w.bin, w.tmp, w.dir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range systemTools {
		if p, err := exec.LookPath(n); err == nil && filepath.IsAbs(p) {
			if err := os.Symlink(p, w.bin+"/"+n); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, s := range stubs {
		w.installStub(s)
	}
	return w
}

// installStub puts a stub tool on the PATH: curl and wget are the frozen shell stubs of the old suite
// (testdata/stubs); the others are one-liners.
func (w *world) installStub(name string) {
	w.t.Helper()
	switch name {
	case "curl", "wget":
		b, err := os.ReadFile("testdata/stubs/" + name)
		if err != nil {
			w.t.Fatal(err)
		}
		execfile.Write(w.t, w.bin+"/"+name, string(b))
	case "pandoc": // pandoc -f html -t gfm IN -o OUT : upper-cases the page
		execfile.Write(w.t, w.bin+"/pandoc", "#!/usr/bin/env bash\nin=\"${@: -3:1}\"; out=\"${@: -1}\"\ntr a-z A-Z < \"$in\" > \"$out\"\n")
	case "pandoc-fail":
		execfile.Write(w.t, w.bin+"/pandoc", "#!/usr/bin/env bash\nout=\"${@: -1}\"; printf PARTIAL > \"$out\"; exit 3\n")
	case "pandoc-hang": // announces itself, then blocks until signalled (a TERM must kill it and its sleep)
		execfile.Write(w.t, w.bin+"/pandoc", "#!/usr/bin/env bash\nout=\"${@: -1}\"; printf PARTIAL > \"$out\"; : > \"$STUB_HANG_MARKER\"\nsleep 20 & echo $! > \"$STUB_HANG_PIDFILE\"; wait\n")
	case "pdftoppm": // pdftoppm -r 300 -png PDF PREFIX : two pages
		execfile.Write(w.t, w.bin+"/pdftoppm", "#!/usr/bin/env bash\nprefix=\"${@: -1}\"; echo page1 > \"$prefix-1.png\"; echo page2 > \"$prefix-2.png\"\n")
	case "pdftoppm-fail":
		execfile.Write(w.t, w.bin+"/pdftoppm", "#!/usr/bin/env bash\nexit 1\n")
	case "tesseract": // tesseract IMG stdout : prints the image text
		execfile.Write(w.t, w.bin+"/tesseract", "#!/usr/bin/env bash\ncat \"$1\" | sed 's/^/TEXT:/'\n")
	default:
		w.t.Fatalf("unknown stub %q", name)
	}
}

// environ is the child environment of this world.
func (w *world) environ() []string {
	return append([]string{"PATH=" + w.bin, "HOME=" + w.root, "TMPDIR=" + w.tmp, "LC_ALL=C"}, w.extraEnv...)
}

func (w *world) setEnv(kv ...string) { w.extraEnv = append(w.extraEnv, kv...) }

// path is dir-relative to an absolute path in the target directory.
func (w *world) path(rel string) string { return w.dir + "/" + rel }

func (w *world) write(rel, body string) {
	w.t.Helper()
	p := w.path(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// ran is the observable result of one run.
type ran struct {
	out, err string
	rc       int
	tree     string // sorted "path<TAB>content" lines of the target directory, plus the TMPDIR listing
}

// goRun runs the Go command in process in w.
func (w *world) goRun(args ...string) ran { return w.goRunSig(nil, 4242, args...) }

// goRunSig is goRun with a signal source and the pid the run believes it has.
func (w *world) goRunSig(sigs <-chan os.Signal, pid int, args ...string) ran {
	w.t.Helper()
	var out, errb bytes.Buffer
	environ := w.environ()
	env := map[string]string{}
	for _, kv := range environ {
		k, v, _ := strings.Cut(kv, "=")
		env[k] = v
	}
	look := probe.New(environ, w.dir).LookPath
	rc := Execute(args, Deps{
		Out: &out, Err: &errb, Env: func(k string) string { return env[k] }, Environ: environ,
		Now: func() time.Time { return fixedNow }, Pid: pid, Signals: sigs, TmpDir: w.tmp,
		Run: runner.Exec{Env: environ, Look: look}, Look: look, Hash: w.hash,
	})
	return ran{out: out.String(), err: errb.String(), rc: rc, tree: w.snapshot()}
}

var dateCell = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ`)

// norm makes a result comparable across worlds: the world's root, the pid and every timestamp are replaced.
func (w *world) norm(s string) string {
	s = strings.ReplaceAll(s, w.root, "<R>")
	return dateCell.ReplaceAllString(s, "<DATE>")
}

// snapshot lists every file under the target directory and TMPDIR with its content (a symlink with its target).
func (w *world) snapshot() string {
	var lines []string
	for _, base := range []string{w.dir, w.tmp} {
		_ = filepath.Walk(base, func(p string, fi os.FileInfo, err error) error {
			if err != nil || p == base {
				return nil
			}
			rel := strings.TrimPrefix(p, w.root+"/")
			switch {
			case fi.Mode()&os.ModeSymlink != 0:
				tgt, _ := os.Readlink(p)
				lines = append(lines, rel+"\t-> "+tgt)
			case fi.IsDir():
				lines = append(lines, rel+"/")
			default:
				b, _ := os.ReadFile(p)
				lines = append(lines, rel+"\t"+strings.ReplaceAll(string(b), "\n", "\\n"))
			}
			return nil
		})
	}
	sort.Strings(lines)
	return w.norm(strings.Join(lines, "\n"))
}
