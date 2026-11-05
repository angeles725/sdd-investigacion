package flakehunt

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// tools are linked into a world's PATH: the legacy script and the fake suites need exactly these.
var pathTools = []string{"bash", "env", "timeout", "nproc", "date", "mkdir", "rm", "rmdir", "grep", "dirname", "basename",
	"readlink", "cat", "sleep", "sed", "sort", "mktemp", "wc", "tr", "head", "tail", "awk", "seq", "touch", "ls", "ps",
	"pwd", "cut", "uniq", "printf", "true", "false", "sh"}

// world is one hermetic case: a kit repository with fake suites, a PATH made only of symlinks (so a tool can be
// dropped), a recording directory for the stubs and the suites, and the environment of the run.
type world struct {
	t                          *testing.T
	root, repo, bin, home, rec string
	cwd                        string
	env                        []string
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "fh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, repo: root + "/repo", bin: root + "/bin", home: root + "/home", rec: root + "/rec", cwd: root + "/cwd"}
	for _, d := range []string{w.repo, w.bin, w.home, w.rec, w.cwd} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, tool := range pathTools {
		for _, d := range []string{"/usr/local/bin", "/usr/bin", "/bin"} {
			if fi, err := os.Stat(d + "/" + tool); err == nil && !fi.IsDir() {
				_ = os.Symlink(d+"/"+tool, w.bin+"/"+tool)
				break
			}
		}
	}
	w.env = []string{"PATH=" + w.bin, "HOME=" + w.home, "LC_ALL=C"}
	return w
}

// suite writes a fake suite <repo>/s/<name> and returns its repo-relative path.
func (w *world) suite(name, body string) string {
	w.t.Helper()
	execfile.Write(w.t, w.repo+"/s/"+name, "#!/usr/bin/env bash\n"+body+"\n")
	return "s/" + name
}

// drop removes a tool from the PATH (a missing dependency).
func (w *world) drop(tool string) {
	w.t.Helper()
	if err := os.Remove(w.bin + "/" + tool); err != nil {
		w.t.Fatal(err)
	}
}

// file writes a plain file below the world root.
func (w *world) file(rel, content string) {
	w.t.Helper()
	p := filepath.Join(w.root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// expand replaces the placeholders a scenario writes: @R@ repo, @W@ root, @O@ out directory, @REC@ recordings.
func (w *world) expand(s string) string {
	return strings.NewReplacer("@R@", w.repo, "@W@", w.root, "@O@", w.root+"/o1", "@REC@", w.rec).Replace(s)
}

// ran is one finished run.
type ran struct {
	out, err string
	rc       int
}

// stdio is the cli.Stdio of a run in this world.
func (w *world) stdio() (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	env := append([]string(nil), w.env...)
	get := func(k string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, k+"="); ok {
				v = s
			}
		}
		return v
	}
	var o, e bytes.Buffer
	return cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return env },
		Clock: time.Now, Cwd: w.cwd}, &o, &e
}

// goRun runs the Go command with no signal source.
func (w *world) goRun(args ...string) ran {
	w.t.Helper()
	return w.goRunWith(deps{}, args...)
}

func (w *world) goRunWith(d deps, args ...string) ran {
	w.t.Helper()
	s, o, e := w.stdio()
	rc := run(args, s, d)
	return ran{o.String(), e.String(), rc}
}

// stubGH writes a gh stub into the PATH: it records its arguments, its cwd and GH_TOKEN, answers `issue list` from
// rec/gh-existing (rc 1 when rec/gh-fail exists) and `issue create` / `issue comment` with rc 1 when rec/gh-mutfail
// exists. Nothing here can reach a network.
func (w *world) stubGH() {
	w.t.Helper()
	execfile.Write(w.t, w.bin+"/gh", fmt.Sprintf(`#!/usr/bin/env bash
R=%s
printf '%%s|' "$@" >>"$R/gh.log"; echo >>"$R/gh.log"; pwd >>"$R/gh.cwd"
printf '%%s\n' "${GH_TOKEN-unset}" >>"$R/gh.tok"
case "$1 $2" in
  "issue list") [ -f "$R/gh-fail" ] && exit 1; [ -f "$R/gh-existing" ] && cat "$R/gh-existing"; exit 0 ;;
  "issue create") [ -f "$R/gh-mutfail" ] && exit 1; echo "https://example.invalid/issues/1"; exit 0 ;;
  "issue comment") [ -f "$R/gh-mutfail" ] && exit 1; exit 0 ;;
esac
exit 0
`, w.rec))
}

// stubNode writes a node stub that runs the file as a bash script, so a *.test.mjs fixture needs no real node.
func (w *world) stubNode() {
	w.t.Helper()
	execfile.Write(w.t, w.bin+"/node", "#!/usr/bin/env bash\nexec bash \"$@\"\n")
}

// stubRunAll writes <repo>/research-sdd/toolbelt/tests/run-all.sh: it logs its arguments to rec/ra.log, rejects
// --tier core unless rec/accept-tier exists (then it lists core), fails when rec/ra-fail exists and otherwise lists full.
func (w *world) stubRunAll(core, full string) {
	w.t.Helper()
	execfile.Write(w.t, w.repo+"/research-sdd/toolbelt/tests/run-all.sh", fmt.Sprintf(`#!/usr/bin/env bash
echo "$*" >>%[1]s/ra.log
case "$*" in
  *"--tier core"*) [ -f %[1]s/accept-tier ] || { echo "usage: run-all.sh ..." >&2; exit 2; }; printf '%%b' %[2]q; exit 0 ;;
esac
[ -f %[1]s/ra-fail ] && exit 1
printf '%%b' %[3]q
`, w.rec, core, full))
}

// leftovers lists the processes whose command line carries tag (the busy-loop workers of one output directory).
func leftovers(tag string) []string {
	var out []string
	ents, _ := filepath.Glob("/proc/[0-9]*/cmdline")
	for _, e := range ents {
		b, err := os.ReadFile(e)
		if err == nil && strings.Contains(string(b), tag) {
			out = append(out, e)
		}
	}
	return out
}
