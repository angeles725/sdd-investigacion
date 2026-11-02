//go:build unix && !nodiff

package sweep

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parity"
)

// The differential: the frozen sweep-retros.sh and sweep-retros-hook.sh (testdata/legacy: the bytes of the
// scripts before the port; the live ones are shims now) run beside the Go commands in the same world. The
// scripts source the LIVE toolbelt/lib through a staged lib link, so the bash libs stay under test too. Stdout,
// stderr (timings of the profile aside) and the exit code must be equal. A missing bash, git or jq FAILS: a
// skipped differential proves nothing. Fixtures keep hours or days of margin around every threshold because
// the script reads the real clock a few seconds after the world was built.

const (
	moduleRoot = "../.."
	toolbelt   = "../../../toolbelt"
)

var (
	rsddOnce sync.Once
	rsddDir  string
	rsddPath string
	rsddErr  error
)

func rsddBinary(t testing.TB) string {
	t.Helper()
	rsddOnce.Do(func() {
		rsddDir, rsddErr = os.MkdirTemp("", "sweep-diff-rsdd-")
		if rsddErr == nil {
			rsddPath, rsddErr = parity.BuildBinary(moduleRoot, rsddDir)
		}
	})
	if rsddErr != nil {
		t.Fatalf("building rsdd for the legacy hook-wiring lib: %v", rsddErr)
	}
	return rsddPath
}

func TestMain(m *testing.M) {
	code := m.Run()
	if rsddDir != "" {
		_ = os.RemoveAll(rsddDir)
	}
	os.Exit(code)
}

// stageLegacy puts the frozen scripts in <kit>/toolbelt, with lib/ linked to the live library.
func (w *world) stageLegacy() {
	w.t.Helper()
	lib, err := filepath.Abs(toolbelt + "/lib")
	w.must(err)
	for _, n := range []string{"sweep-retros.sh", "sweep-retros-hook.sh"} {
		b, err := os.ReadFile("testdata/legacy/" + n)
		w.must(err)
		w.must(os.WriteFile(w.kit+"/toolbelt/"+n, b, 0o755))
	}
	if _, err := os.Lstat(w.kit + "/toolbelt/lib"); err != nil {
		w.must(os.Symlink(lib, w.kit+"/toolbelt/lib"))
	}
}

// bash runs a staged script.
func (w *world) bash(script string, args ...string) result {
	w.t.Helper()
	w.stageLegacy()
	cmd := exec.Command("bash", append([]string{w.kit + "/toolbelt/" + script}, args...)...)
	cmd.Dir = w.root
	cmd.Env = append(w.environ(), "RSDD_BIN="+rsddBinary(w.t))
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatalf("bash %s: %v", script, err)
		}
		rc = ee.ExitCode()
	}
	return result{o.String(), e.String(), rc}
}

var reProfile = regexp.MustCompile(`(profile: [a-z-]+) [0-9]+\.[0-9]+`)

func normProfile(s string) string { return reProfile.ReplaceAllString(s, "$1 <t>") }

// reAwkFatal is the awk diagnostic of an unreadable retro: the bash lib reads the file through awk, which Go
// does not, so that one line has no equivalent (the retro-grammar line before it is kept).
var reAwkFatal = regexp.MustCompile(`(?m)^awk: .*\n`)

// reAwkInHook is the same line inside the hook envelope, where the newlines are JSON escapes.
var reAwkInHook = regexp.MustCompile(`awk: cmd\. line:[0-9]+: fatal: .*?Permission denied(\\n)?`)

func normStderr(s string) string { return reAwkFatal.ReplaceAllString(normProfile(s), "") }

func normOut(s string) string { return reAwkInHook.ReplaceAllString(normProfile(s), "") }

func (w *world) same(what string, goRes, bashRes result) {
	w.t.Helper()
	if goRes.rc != bashRes.rc || normOut(goRes.out) != normOut(bashRes.out) || normStderr(goRes.err) != normStderr(bashRes.err) {
		w.t.Errorf("%s differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
			what, goRes.rc, goRes.out, goRes.err, bashRes.rc, bashRes.out, bashRes.err)
	}
}

func TestRetrosDifferential(t *testing.T) {
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range sc.env {
				w.env[k] = v
			}
			sc.setup(w)
			w.same("report", w.run(sc.args...), w.bash("sweep-retros.sh", sc.args...))
			if len(sc.args) == 0 {
				w.same("hook", w.runHook(), w.bash("sweep-retros-hook.sh"))
				w.same("hook --full", w.runHook("--full"), w.bash("sweep-retros-hook.sh", "--full"))
			}
		})
	}
}

// TestRetrosDifferentialOrder pins the readdir order of the WARN lines of the pending pass and the tie-break of
// retros of the same age, over a target whose retros sit at several depths.
func TestRetrosDifferentialOrder(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, n := range []string{"b.md", "a.md", "C.md", "10.md", "2.md", "z.md", "m.md"} {
		w.put(a+"/retros/"+n, retroText("", 1))
	}
	for _, d := range []string{"x/retros", "x/y/retros", "x/y/z/retros", "x/y/z/w/retros"} {
		w.put(a+"/"+d+"/n.md", retroText("<!-- review-status: wip -->", 2))
	}
	w.put(a+"/retros/sub/dir/deep.md", retroText("", 3))
	w.put(a+"/retros/.hidden.md", retroText("", 1))
	w.put(a+"/retros/notes.txt", "not markdown\n")
	w.put(a+"/.git/retros/in-git.md", retroText("", 1))
	w.must(os.Symlink(a+"/retros/a.md", a+"/retros/link.md"))
	w.must(os.Symlink(a+"/x", a+"/linkdir"))
	w.targets(a)
	w.same("report", w.run(), w.bash("sweep-retros.sh"))
}

// TestRetrosDifferentialSymlinkTarget pins `find /link` listing only the link: a target registered as a symbolic
// link to a directory holds no retro for the sweep, though [ -d ] accepts it.
func TestRetrosDifferentialSymlinkTarget(t *testing.T) {
	w := newWorld(t)
	real := w.tgt("real")
	w.retro(real, "r1.md", pendingMarker, 1)
	link := w.root + "/link"
	w.must(os.Symlink(real, link))
	w.put(real+"/t-block1.md", "# b\n")
	w.touch(real+"/t-block1.md", 2*day)
	w.targets(link, real)
	w.same("report", w.run(), w.bash("sweep-retros.sh"))
}

// TestRetrosDifferentialDuplicates pins the canonical-path dedup: a retro reachable through two registered
// targets (a nested target and its parent) counts once.
func TestRetrosDifferentialDuplicates(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a+"/sub", "r1.md", pendingMarker, 2)
	w.retro(a, "r0.md", "", 1)
	w.targets(a, a+"/sub", a)
	w.same("report", w.run(), w.bash("sweep-retros.sh"))
}

func TestRetrosDifferentialUnusual(t *testing.T) {
	for name, setup := range map[string]func(w *world){
		"trailing slash target": func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.targets(a + "/")
		},
		"unreadable retro": func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.must(os.Chmod(a+"/retros/r1.md", 0))
			w.targets(a)
		},
		"retros path inside the target prefix": func(w *world) {
			a := w.tgt("retros/targetA")
			w.put(a+"/note.md", retroText("", 1))
			w.targets(a)
		},
		"directory named like a retro": func(w *world) {
			a := w.tgt("targetA")
			w.must(os.MkdirAll(a+"/retros/odd.md", 0o755))
			w.targets(a)
		},
		"CRLF retro and BOM": func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/r1.md", "\xef\xbb\xbf<!-- review-status: pending -->\r\n# retro\r\n\r\n## Proposed kit deltas\r\n\r\n| # | d |\r\n|---|---|\r\n| 1 | x |\r\n")
			w.targets(a)
		},
		"grace hours octal": func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/t-block1.md", "# b\n")
			w.touch(a+"/t-block1.md", 30*hour)
			w.env["RSDD_MISSING_RETRO_GRACE_HOURS"] = "010"
			w.targets(a)
		},
		"age threshold zero": func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.touch(a+"/retros/r1.md", 2*day)
			w.env["RSDD_RETRO_AGE_DAYS"] = "0"
			w.targets(a)
		},
		"two tied retros": func(w *world) {
			a := w.tgt("targetA")
			for _, n := range []string{"b.md", "B.md", "a.md", "_.md", "1.md"} {
				w.retro(a, n, pendingMarker, 1)
				w.touch(a+"/retros/"+n, 3*day)
			}
			w.targets(a)
		},
	} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			setup(w)
			w.same("report", w.run(), w.bash("sweep-retros.sh"))
			w.same("json", w.run("--json"), w.bash("sweep-retros.sh", "--json"))
			w.same("hook", w.runHook(), w.bash("sweep-retros-hook.sh"))
		})
	}
}
