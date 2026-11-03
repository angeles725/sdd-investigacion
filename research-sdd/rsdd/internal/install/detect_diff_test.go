//go:build unix && !nodiff

package install

import (
	"bytes"
	"errors"
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

// Differential test: the frozen toolbelt/detect-tools.sh (testdata/legacy/detect-tools, with the lib/tool-env.sh it
// sources) and `rsdd install detect-tools` run on the same fixture and must agree on stdout, stderr, the exit code and
// the cache file. Both sides see only fixture paths: the frozen script runs from a copy whose hardcoded host paths
// (/usr/bin/..., /opt/ghidra*, /usr/lib/jvm) point under the fixture root, and the Go side gets the same root, so no real
// tool or Java runs. A missing bash FAILS the test: a skipped differential proves nothing.

var dateField = regexp.MustCompile(`date: \S+`)

// coreutils the frozen script runs by name; linked into the private PATH so both sides find them.
var legacyCoreutils = []string{"dirname", "basename", "grep", "head", "sed", "mkdir", "date", "uname", "sort", "realpath", "env", "cat", "tr"}

type diffRes struct {
	out, err, cache string
	code            int
}

func legacyDir(t *testing.T) string {
	t.Helper()
	d, err := filepath.Abs("testdata/legacy/detect-tools")
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// hostPaths are the absolute host locations the frozen script hardcodes. legacyScript points them at the fixture
// root in a COPY (the oracle under testdata stays verbatim), so the script and the Go command, which gets the same
// root through dt.tweak, probe only fixture paths.
var hostPaths = []string{"/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/share/", "/opt/ghidra", "/home/linuxbrew"}

func (e *dt) legacyScript() string {
	e.t.Helper()
	dir := e.root + "/legacy"
	if _, err := os.Stat(dir + "/detect-tools.sh"); err == nil {
		return dir + "/detect-tools.sh"
	}
	if err := os.MkdirAll(dir+"/lib", 0o755); err != nil {
		e.t.Fatal(err)
	}
	for _, f := range []string{"detect-tools.sh", "lib/tool-env.sh"} {
		b, err := os.ReadFile(legacyDir(e.t) + "/" + f)
		if err != nil {
			e.t.Fatal(err)
		}
		s := string(b)
		for _, p := range hostPaths {
			s = strings.ReplaceAll(s, p, e.root+p)
		}
		s = strings.Replace(s, "#!"+e.root+"/usr/bin/env bash", "#!/usr/bin/env bash", 1)
		if err := os.WriteFile(dir+"/"+f, []byte(s), 0o755); err != nil {
			e.t.Fatal(err)
		}
	}
	return dir + "/detect-tools.sh"
}

func (e *dt) environList() []string {
	var keys []string
	for k := range e.env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var out []string
	for _, k := range keys {
		out = append(out, k+"="+e.env[k])
	}
	return out
}

func (e *dt) readCache() string {
	b, err := os.ReadFile(e.env["RESEARCH_TOOLS_CACHE"])
	if err != nil {
		return "<no cache: " + err.Error() + ">"
	}
	os.Remove(e.env["RESEARCH_TOOLS_CACHE"])
	return string(b)
}

func (e *dt) legacy(args ...string) diffRes {
	e.t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		e.t.Fatalf("bash is required for the differential test: %v", err)
	}
	var out, er bytes.Buffer
	c := exec.Command(bash, append([]string{e.legacyScript()}, args...)...)
	c.Dir, c.Env, c.Stdout, c.Stderr = e.cwd, e.environList(), &out, &er
	rc := 0
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			e.t.Fatalf("cannot run the legacy script: %v", err)
		}
		rc = ee.ExitCode()
	}
	return diffRes{out.String(), er.String(), e.readCache(), rc}
}

func (e *dt) golang(args ...string) diffRes {
	e.t.Helper()
	environ := e.environList()
	var out, er bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &er, Environ: func() []string { return environ },
		Env: func(k string) string { return e.env[k] }, Clock: time.Now, Cwd: e.cwd}
	// the shim passes its own path as --prog; the legacy script prints $0, the path it was started with
	code := runDetect(append([]string{"--prog", e.legacyScript()}, args...), s, e.tweak)
	return diffRes{out.String(), er.String(), e.readCache(), code}
}

func maskDate(s string) string { return dateField.ReplaceAllString(s, "date: <D>") }

// same fails unless both sides agree on every observable effect. Cases whose message is a deliberate divergence
// compare only the exit code (loose).
func (e *dt) same(name string, args ...string) {
	e.t.Helper()
	l, g := e.legacy(args...), e.golang(args...)
	for field, pair := range map[string][2]string{
		"stdout": {maskDate(l.out), maskDate(g.out)}, "stderr": {l.err, g.err}, "cache": {maskDate(l.cache), maskDate(g.cache)},
	} {
		if pair[0] != pair[1] {
			e.t.Errorf("%s %q: %s differs\n%s", name, args, field, firstDiff(pair[0], pair[1]))
		}
	}
	if l.code != g.code {
		e.t.Errorf("%s %q: exit legacy %d, rsdd %d", name, args, l.code, g.code)
	}
	// a differential that compares two empty reports proves nothing
	if len(args) == 0 && !strings.Contains(l.out, "== Research-SDD tool capability report ==") {
		e.t.Errorf("%s: the legacy run produced no report: %q / %q", name, l.out, l.err)
	}
}

func newDiff(t *testing.T) *dt {
	e := newDT(t)
	e.link(legacyCoreutils...)
	return e
}

// Both sides resolve the fixed host paths under the fixture root: a fake planted at <root>/usr/bin/objdump is the tool
// both report, and the machine's real /usr/bin/objdump is never what runs.
func TestDiffFixedPathsAreTheFixtures(t *testing.T) {
	e := newDiff(t)
	e.tool(e.root+"/usr/bin/objdump", "exit 0")
	e.tool(e.root+"/usr/sbin/unsquashfs", "exit 0")
	want := []string{"AVAILABLE   " + e.root + "/usr/bin/objdump", "AVAILABLE   " + e.root + "/usr/sbin/unsquashfs"}
	for side, r := range map[string]diffRes{"legacy": e.legacy(), "rsdd": e.golang()} {
		for _, w := range want {
			if !strings.Contains(r.out, w) {
				t.Errorf("%s report lacks %q:\n%s", side, w, firstDiff(r.out, w))
			}
		}
		if row := rowOf(r.out, "gdb"); !strings.Contains(row, "MISSING") {
			t.Errorf("%s: gdb row %q — a real /usr/bin/gdb leaked in", side, row)
		}
	}
	e.same("fixed-paths")
}

func TestDiffAllMissing(t *testing.T) {
	e := newDiff(t)
	e.same("all-missing")
	e.same("quiet", "--quiet")
}

func TestDiffRowStatuses(t *testing.T) {
	e := newDiff(t)
	e.tool("objdump", "exit 0")
	e.tool("nm", "exit 1")
	e.tool("readelf", "sleep 5")
	e.tool("strings", "exit 0")
	if err := os.Chmod(e.bin+"/strings", 0o644); err != nil {
		t.Fatal(err)
	}
	e.tool("marker_single", "sleep 5")
	e.tool("docling", "exit 3")
	e.tool("hexedit", `[ "$1" = --help ] || exit 9`)
	e.tool("pwsh", `printf '%s\n' "${DOTNET_EnableDiagnostics:-unset}" > "$RSDD_LOG"; exit 0`)
	e.env["RSDD_LOG"] = e.root + "/pwsh.log"
	e.same("statuses")
	e.tool(e.brew+"/bin/r2", "exit 0")
	e.tool(e.home+"/.local/bin/capa", "exit 0")
	e.tool(e.brew+"/bin/capa", "exit 1")
	e.tool(e.home+"/dev/pycdc/pycdc", "exit 0")
	e.same("candidates")
	if err := os.Remove(e.bin + "/timeout"); err != nil {
		t.Fatal(err)
	}
	e.same("no-timeout")
}

func TestDiffJarsAndJava(t *testing.T) {
	e := newDiff(t)
	e.link("sha256sum")
	e.tool("unzip", `case "$1" in -tqq) exit 0;; -Z1) printf '%s\n' "$3"; exit 0;; esac; exit 2`)
	jarDir := e.root + "/toolhome/java"
	if err := os.MkdirAll(jarDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"vineflower", "cfr"} {
		if err := os.WriteFile(jarDir+"/"+n+".jar", []byte("JAR-"+n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	e.same("jars-ok")
	e.tool("unzip", `case "$1" in -tqq) exit 0;; -Z1) echo wrong; exit 0;; esac`)
	e.same("jar-wrong-entry")
	e.tool("unzip", `exit 1`)
	e.same("jar-corrupt")
	if err := os.Remove(e.bin + "/unzip"); err != nil {
		t.Fatal(err)
	}
	e.same("jar-no-unzip")
	e.env["CFR_JAR"] = e.root + "/missing.jar"
	e.same("jar-bad-override")
	e.tool("java", "sleep 5") // the host's real Java resolution is the same for both sides
	e.same("java-path-sleeping")
	e.tool("java", "exit 1")
	e.same("java-path-failing")
}

func TestDiffDotnetAndPackages(t *testing.T) {
	e := newDiff(t)
	runtime := e.root + "/runtime"
	if err := os.MkdirAll(runtime+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && [ "$DOTNET_EnableDiagnostics" = 0 ] && exit 0; exit 1`)
	e.env["RSDD_DOTNET_ROOT"] = runtime
	e.same("ilspy-ok")
	e.env["RSDD_DOTNET_ROOT"] = e.root + "/empty"
	e.same("ilspy-bad-root") // includes the ERROR line on stderr
	delete(e.env, "RSDD_DOTNET_ROOT")
	e.env["DOTNET_ROOT"] = runtime
	e.same("ilspy-ambient")
	delete(e.env, "DOTNET_ROOT")
	e.tool(runtime+"/dotnet", "exit 0")
	if err := os.Symlink(runtime+"/dotnet", e.bin+"/dotnet"); err != nil {
		t.Fatal(err)
	}
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && exit 0; exit 1`)
	e.same("ilspy-derived")

	e.tool("pkg-config", `[ "$2" = libhs ] || exit 1; echo 5.4.2`)
	e.tool("kpsewhich", `echo /tex/circuitikz.sty`)
	e.tool("python3", `[ "$2" = "import ezdxf" ] && exit 0; exit 1`)
	venv := e.root + "/venv"
	e.env["RESEARCH_SDD_VENV"] = venv
	e.tool(venv+"/bin/python", `exit 0`)
	e.tool(venv+"/bin/ocrmypdf", "exit 0")
	e.same("packages")
}

func TestDiffBinwalk(t *testing.T) {
	e := newDiff(t)
	v3 := `if [ "${1:-}" = --version ]; then echo "binwalk 3.1.0"; else echo "Usage: binwalk [OPTIONS]"; fi`
	for name, body := range map[string]string{"v3": v3, "v2": `echo "Binwalk v2.3.3"`, "none": `echo hello`, "greedy": `echo "Binwalk v2.1 and binwalk 3.0.1 built"`} {
		e.tool("binwalk", body)
		e.same("binwalk-" + name)
	}
	e.env["RSDD_BINWALK"] = e.tool(e.root+"/bw3/binwalk", v3)
	e.same("binwalk-env")
	e.env["RSDD_BINWALK"] = e.root + "/no-such"
	e.same("binwalk-env-missing")
}

func TestDiffRequireAndFlags(t *testing.T) {
	e := newDiff(t)
	e.env["RSDD_PROBE_TIMEOUT"] = "2" // a loaded host must not turn a quick fake into a probe failure
	e.tool("objdump", "exit 0")
	e.tool("nm", "exit 1")
	for _, list := range []string{"objdump", "ghidra", "nm", "objdump,nm,ghidra", "objdump,", "nm,bogus,ghidra", "objdump,,nm", ",", "r2", "java", "ksc"} {
		e.same("require", "--require", list)
	}
	e.env["RSDD_PROBE_TIMEOUT"] = "0.5"
	e.tool("readelf", "sleep 9")
	e.same("require-probe-failed", "--require", "readelf")
	if err := os.Remove(e.bin + "/readelf"); err != nil {
		t.Fatal(err)
	}
	e.same("require-quiet", "--quiet", "--require", "nm")
	e.same("require-newline", "--require", "objdump\nbogus")
	e.same("require-twice", "--require", "nm", "--require", "objdump")
	for _, args := range [][]string{{"--bogus"}, {"--require"}, {"--require", ""}, {"--quiet", "extra"}, {"--cache", "x", "--bogus"}} {
		e.same("usage", args...)
	}
}

func TestDiffCache(t *testing.T) {
	e := newDiff(t)
	// default location, XDG and a relative --cache
	delete(e.env, "RESEARCH_TOOLS_CACHE")
	e.env["RESEARCH_TOOLS_CACHE"] = e.home + "/.cache/research-sdd/tool-capabilities.txt"
	e.same("default", "--quiet")
	e.env["RESEARCH_TOOLS_CACHE"] = e.cwd + "/rel/dir/c.txt"
	e.same("relative", "--cache", "rel/dir/c.txt")
	// errors: the message names the script, the same on both sides
	if err := os.WriteFile(e.root+"/afile", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []string{e.root + "/afile/sub/c.txt", e.root} {
		e.env["RESEARCH_TOOLS_CACHE"] = c
		// the tools the script shells out to (mkdir, the bash redirect) add their own stderr lines first; the
		// script's own message is the last line, and the exit codes agree
		l, g := e.legacy("--quiet"), e.golang("--quiet")
		lines := strings.Split(strings.TrimRight(l.err, "\n"), "\n")
		if l.code != 1 || g.code != 1 || lines[len(lines)-1] != strings.TrimRight(g.err, "\n") || l.out != "" || g.out != "" {
			t.Errorf("cache-error %s: legacy exit %d %q, rsdd exit %d %q", c, l.code, l.err, g.code, g.err)
		}
	}
	// a bare or empty --cache is exit 1 on both sides; only the message differs (bash: "line N: 2: path")
	for _, args := range [][]string{{"--cache"}, {"--cache", ""}} {
		if l, g := e.legacy(args...), e.golang(args...); l.code != 1 || g.code != 1 || g.err == "" || l.err == "" {
			t.Errorf("%q: legacy exit %d (%q), rsdd exit %d (%q), want exit 1 with a message on both", args, l.code, l.err, g.code, g.err)
		}
	}
}
