//go:build unix

package install

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
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

// Tool-free tests of `rsdd install detect-tools` (no bash, no python: fake tools are /bin/sh scripts). Each case pins one
// rule of toolbelt/detect-tools.sh; detect_diff_test.go (built without the nodiff tag) holds the command to the frozen
// script on the same fixtures. Guard-to-test table (each guard turns one test red when removed):
//
//	status rows (AVAILABLE/UNUSABLE/PROBE_FAILED/MISSING) ... TestRowStatuses, TestNoTimeoutBinaryIsProbeFailed
//	candidate order (PATH, fixed, $HOME, brew)              ... TestCandidateOrder
//	jar validation + sha256 + unzip missing                 ... TestJarRows
//	java home + secondary probe                             ... TestJavaRows
//	ghidra headless probe                                   ... TestGhidraRow
//	ilspycmd DOTNET_ROOT resolution + diagnostics off       ... TestIlspyRow, TestPwshDiagnosticsOff
//	hyperscan / kpsewhich / ezdxf / pymupdf4llm             ... TestPackageProbes
//	binwalk major-2 note                                    ... TestBinwalkNote
//	cache location / errors / quiet                         ... TestCache*
//	--require gate                                          ... TestRequire*
//	usage + --prog                                          ... TestUsage
//	label table <-> report rows                             ... TestEveryRequireLabelHasARow, TestAllMissingGolden

var dtClock = time.Date(2026, 11, 2, 12, 30, 45, 0, time.UTC)

// dt is one hermetic detect-tools run: a private PATH of fakes, HOME, brew prefix and fixed-host-path root.
type dt struct {
	t                     *testing.T
	root, bin, home, brew string
	cwd                   string
	env                   map[string]string
	javaHome, ghidraHome  func() (string, error)
	linked                map[string]bool
}

func newDT(t *testing.T) *dt {
	t.Helper()
	root := t.TempDir()
	e := &dt{t: t, root: root, bin: root + "/bin", home: root + "/home", brew: root + "/brew", cwd: root + "/cwd", linked: map[string]bool{}}
	for _, d := range []string{e.bin, e.home, e.cwd} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	e.env = map[string]string{
		"PATH": e.bin, "HOME": e.home, "RSDD_BREW_PREFIX": e.brew,
		"RSDD_PROBE_TIMEOUT": "0.5", "RSDD_PYTHON_PROBE_TIMEOUT": "0.5",
		"RSDD_SYSTEM_PKGCONFIG_PATH": root + "/pkgconfig", "RESEARCH_SDD_TOOL_HOME": root + "/toolhome",
		"RESEARCH_TOOLS_CACHE": root + "/cache.txt",
	}
	e.javaHome = func() (string, error) { return "", errors.New("no java") }
	e.ghidraHome = func() (string, error) { return "", errors.New("no ghidra") }
	e.link("timeout", "sleep")
	return e
}

// link symlinks real host binaries into the private PATH.
func (e *dt) link(names ...string) {
	e.t.Helper()
	for _, n := range names {
		p, err := exec.LookPath(n)
		if err != nil {
			e.t.Fatalf("host lacks %s: %v", n, err)
		}
		if err := os.Symlink(p, filepath.Join(e.bin, n)); err != nil && !os.IsExist(err) {
			e.t.Fatal(err)
		}
	}
}

// tool writes an executable /bin/sh fake at path (absolute, or relative to the private bin).
func (e *dt) tool(path, body string) string {
	e.t.Helper()
	if !filepath.IsAbs(path) {
		path = filepath.Join(e.bin, path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		e.t.Fatal(err)
	}
	return path
}

func (e *dt) run(args ...string) (stdout, stderr string, code int) {
	e.t.Helper()
	var keys []string
	for k := range e.env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var environ []string
	for _, k := range keys {
		environ = append(environ, k+"="+e.env[k])
	}
	var out, er bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &er, Environ: func() []string { return environ },
		Env: func(k string) string { return e.env[k] }, Clock: func() time.Time { return dtClock }, Cwd: e.cwd}
	code = runDetect(args, s, func(d *detector) {
		d.root, d.javaHome, d.ghidraHome = e.root, e.javaHome, e.ghidraHome
	})
	return out.String(), er.String(), code
}

// report runs without arguments and returns stdout, failing on a non-zero exit.
func (e *dt) report() string {
	e.t.Helper()
	out, er, code := e.run()
	if code != 0 {
		e.t.Fatalf("exit %d, stderr %q", code, er)
	}
	return out
}

// rowOf is the report line of a label ("" when absent).
func rowOf(report, label string) string {
	prefix := fmt.Sprintf("  %-22s", label)
	for _, ln := range strings.Split(report, "\n") {
		if strings.HasPrefix(ln, prefix) {
			return ln
		}
	}
	return ""
}

func wantRow(t *testing.T, report, label, want string) {
	t.Helper()
	if got := rowOf(report, label); got != fmt.Sprintf("  %-22s", label)+want {
		t.Errorf("row %q:\n got %q\nwant %q", label, got, fmt.Sprintf("  %-22s", label)+want)
	}
}

func TestRowStatuses(t *testing.T) {
	e := newDT(t)
	ok := e.tool("objdump", "exit 0")
	bad := e.tool("nm", "exit 1")
	slow := e.tool("readelf", "sleep 5")
	e.tool("strings", "exit 0")
	if err := os.Chmod(e.bin+"/strings", 0o644); err != nil { // present but not executable
		t.Fatal(err)
	}
	e.tool("marker_single", "sleep 5")
	e.tool("docling", "exit 3")
	e.tool("hexedit", `[ "$1" = --help ] || exit 9`) // the smoke argument of the row is passed through
	rep := e.report()
	wantRow(t, rep, "objdump", " AVAILABLE   "+ok)
	wantRow(t, rep, "nm", " UNUSABLE    "+bad+" (smoke test failed)")
	wantRow(t, rep, "readelf", " PROBE_FAILED "+slow+" (probe error: exit 124)")
	wantRow(t, rep, "strings", " UNUSABLE    "+e.bin+"/strings (smoke test failed)")
	wantRow(t, rep, "marker", " PROBE_FAILED "+e.bin+"/marker_single (probe error: exit 124)")
	wantRow(t, rep, "docling", " UNUSABLE    "+e.bin+"/docling (entrypoint smoke test failed)")
	wantRow(t, rep, "hexedit", " AVAILABLE   "+e.bin+"/hexedit")
	wantRow(t, rep, "gdb", " MISSING     (not on PATH nor known install dirs)")
}

func TestPythonRowTimeoutKillIsProbeFailed(t *testing.T) {
	e := newDT(t)
	e.tool("marker_single", "kill -9 $$") // SIGKILLed probe: 137 is a probe failure for python rows only
	e.tool("objdump", "kill -9 $$")
	rep := e.report()
	wantRow(t, rep, "marker", " PROBE_FAILED "+e.bin+"/marker_single (probe error: exit 137)")
	wantRow(t, rep, "objdump", " UNUSABLE    "+e.bin+"/objdump (smoke test failed)")
}

func TestPythonRowUsesItsOwnTimeoutAndEnv(t *testing.T) {
	e := newDT(t)
	e.env["RSDD_PROBE_TIMEOUT"] = "9"
	e.env["RSDD_PYTHON_PROBE_TIMEOUT"] = "0.3"
	e.tool("marker_single", "sleep 5")
	e.tool("objdump", `printf '%s\n' "$RSDD_PROBE_TIMEOUT" > "$RSDD_LOG"`)
	e.tool("docling", `printf '%s\n' "$RSDD_PROBE_TIMEOUT" > "$RSDD_LOG.py"`)
	e.env["RSDD_LOG"] = e.root + "/log"
	start := time.Now()
	rep := e.report()
	if time.Since(start) > 5*time.Second {
		t.Fatalf("the python row waited for RSDD_PROBE_TIMEOUT (9 s) instead of RSDD_PYTHON_PROBE_TIMEOUT")
	}
	wantRow(t, rep, "marker", " PROBE_FAILED "+e.bin+"/marker_single (probe error: exit 124)")
	for f, want := range map[string]string{"/log": "9\n", "/log.py": "0.3\n"} {
		if b, _ := os.ReadFile(e.root + f); string(b) != want {
			t.Errorf("%s = %q, want %q", f, b, want)
		}
	}
}

func TestDefaultPythonTimeoutIs20(t *testing.T) {
	d := newDetector([]string{"RSDD_PYTHON_PROBE_TIMEOUT="}, "/")
	if got := d.pythonTimeout(); got != "20" {
		t.Fatalf("pythonTimeout() = %q, want 20", got)
	}
	if got := d.probeTimeout(); got != "10" {
		t.Fatalf("probeTimeout() = %q, want 10", got)
	}
}

func TestNoTimeoutBinaryIsProbeFailed(t *testing.T) {
	e := newDT(t)
	if err := os.Remove(e.bin + "/timeout"); err != nil {
		t.Fatal(err)
	}
	e.tool("objdump", "exit 0")
	rep := e.report()
	wantRow(t, rep, "objdump", " PROBE_FAILED "+e.bin+"/objdump (probe error: exit 127)")
}

func TestCandidateOrder(t *testing.T) {
	e := newDT(t)
	e.tool(e.root+"/usr/bin/r2", "exit 0")
	e.tool(e.brew+"/bin/r2", "exit 0")
	e.tool(e.brew+"/bin/hexedit", "exit 0")
	e.tool(e.home+"/.local/bin/capa", "exit 0")
	e.tool(e.brew+"/bin/capa", "exit 0")
	e.tool(e.bin+"/floss", "exit 0")
	e.tool(e.home+"/.local/bin/floss", "exit 1")
	e.tool(e.root+"/usr/sbin/unsquashfs", "exit 0")
	e.tool(e.home+"/dev/pycdc/pycdc", "exit 0")
	rep := e.report()
	wantRow(t, rep, "radare2", " AVAILABLE   "+e.brew+"/bin/r2") // brew precedes the fixed /usr/bin
	wantRow(t, rep, "hexedit", " AVAILABLE   "+e.brew+"/bin/hexedit")
	wantRow(t, rep, "capa", " AVAILABLE   "+e.home+"/.local/bin/capa") // $HOME precedes brew
	wantRow(t, rep, "floss", " AVAILABLE   "+e.bin+"/floss")           // PATH precedes every candidate
	wantRow(t, rep, "unsquashfs", " AVAILABLE   "+e.root+"/usr/sbin/unsquashfs")
	wantRow(t, rep, "pycdc", " AVAILABLE   "+e.home+"/dev/pycdc/pycdc")
	if !strings.Contains(rep, "brew: "+e.brew+"\n") {
		t.Errorf("header lacks the brew prefix:\n%s", rep)
	}
}

func TestCandidateGlobAndWordSplit(t *testing.T) {
	e := newDT(t)
	r := &reportCtx{d: newDetector([]string{"PATH="}, e.root)}
	e.tool(e.root+"/cellar/1.2/bin/tool", "exit 0")
	if got, ok := r.resolve("nothere", e.root+"/cellar/*/bin/tool"); !ok || got != e.root+"/cellar/1.2/bin/tool" {
		t.Errorf("glob candidate = (%q, %v)", got, ok)
	}
	if got, ok := r.resolve("nothere", "", "/nonexistent/a "+e.root+"/cellar/1.2/bin/tool"); !ok || got != e.root+"/cellar/1.2/bin/tool" {
		t.Errorf("word-split candidate = (%q, %v)", got, ok)
	}
	if got, ok := r.resolve("nothere", "cellar/*/nope"); ok {
		t.Errorf("unmatched glob resolved to %q", got)
	}
}

func TestJarRows(t *testing.T) {
	e := newDT(t)
	e.link("sha256sum")
	// The fake unzip lists exactly the class the jar must hold; -tqq passes for any non-empty jar.
	e.tool("unzip", `case "$1" in -tqq) exit 0;; -Z1) printf '%s\n' "$3"; exit 0;; esac; exit 2`)
	jarDir := e.root + "/toolhome/java"
	for _, n := range []string{"vineflower", "cfr", "procyon"} {
		if err := os.MkdirAll(jarDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(jarDir+"/"+n+".jar", []byte("JAR-"+n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	sum := sha256.Sum256([]byte("JAR-cfr"))
	digest := hex.EncodeToString(sum[:])
	rep := e.report()
	wantRow(t, rep, "CFR (jar)", fmt.Sprintf(" AVAILABLE   %s/cfr.jar (sha256=%s)", jarDir, digest))
	if !strings.Contains(rowOf(rep, "Vineflower (jar)"), " AVAILABLE   "+jarDir+"/vineflower.jar (sha256=") {
		t.Errorf("vineflower row: %q", rowOf(rep, "Vineflower (jar)"))
	}
	// a jar that does not hold the decompiler class is UNUSABLE
	e.tool("unzip", `case "$1" in -tqq) exit 0;; -Z1) echo other/Class.class; exit 0;; esac`)
	wantRow(t, e.report(), "CFR (jar)", " UNUSABLE    "+jarDir+"/cfr.jar (archive structure/digest validation failed)")
	// a corrupt archive (unzip -tqq fails) is UNUSABLE
	e.tool("unzip", `exit 1`)
	wantRow(t, e.report(), "CFR (jar)", " UNUSABLE    "+jarDir+"/cfr.jar (archive structure/digest validation failed)")
	// no unzip at all: the probe cannot run, PROBE_FAILED with the shell's 127
	if err := os.Remove(e.bin + "/unzip"); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "CFR (jar)", " PROBE_FAILED "+jarDir+"/cfr.jar (probe error: exit 127)")
	// an empty jar is UNUSABLE (checked before unzip is needed)
	if err := os.WriteFile(jarDir+"/cfr.jar", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "CFR (jar)", " UNUSABLE    "+jarDir+"/cfr.jar (archive structure/digest validation failed)")
	// an override that is not a file is MISSING, never a fallback to the installed jar
	e.env["CFR_JAR"] = e.root + "/no-such.jar"
	wantRow(t, e.report(), "CFR (jar)", " MISSING     (jar not found; set the matching env var)")
	delete(e.env, "CFR_JAR")
	// unzip fine but no sha256sum: still UNUSABLE, the digest is part of availability
	if err := os.WriteFile(jarDir+"/cfr.jar", []byte("JAR-cfr"), 0o644); err != nil {
		t.Fatal(err)
	}
	e.tool("unzip", `case "$1" in -tqq) exit 0;; -Z1) printf '%s\n' "$3"; exit 0;; esac`)
	if err := os.Remove(e.bin + "/sha256sum"); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "CFR (jar)", " UNUSABLE    "+jarDir+"/cfr.jar (archive structure/digest validation failed)")
}

func TestProbeJarUnknownName(t *testing.T) {
	e := newDT(t)
	d := newDetector([]string{"PATH=" + e.bin}, e.cwd)
	jar := e.root + "/x.jar"
	if err := os.WriteFile(jar, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rc := d.probeJar("nonesuch", jar); rc != 2 {
		t.Fatalf("probeJar(unknown) = %d, want 2", rc)
	}
	if rc := d.probeJar("cfr", e.root+"/absent.jar"); rc != 1 {
		t.Fatalf("probeJar(absent file) = %d, want 1", rc)
	}
}

func TestJavaRows(t *testing.T) {
	e := newDT(t)
	e.javaHome = func() (string, error) { return "/opt/j21", nil }
	rep := e.report()
	wantRow(t, rep, "Java 21", " AVAILABLE   /opt/j21/bin/java")
	wantRow(t, rep, "javap 21", " AVAILABLE   /opt/j21/bin/javap")

	e.javaHome = func() (string, error) { return "", errors.New("none") }
	rep = e.report()
	wantRow(t, rep, "Java 21", " MISSING     (usable Java 21 + javap not found)")
	wantRow(t, rep, "javap 21", " MISSING     (usable Java 21 + javap not found)")

	// a java on PATH that outlives the probe bound is PROBE_FAILED, not MISSING (the resolver collapses it)
	e.tool("java", "sleep 5")
	rep = e.report()
	wantRow(t, rep, "Java 21", " PROBE_FAILED "+e.bin+"/java (probe error: exit 124)")
	wantRow(t, rep, "javap 21", " PROBE_FAILED "+e.bin+"/java (probe error: exit 124)")

	// a java that simply fails (an old version) is MISSING for the 21 requirement
	e.tool("java", "exit 1")
	wantRow(t, e.report(), "Java 21", " MISSING     (usable Java 21 + javap not found)")

	// without timeout(1) the secondary probe cannot run: 127 is a probe failure too
	if err := os.Remove(e.bin + "/timeout"); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "Java 21", " PROBE_FAILED "+e.bin+"/java (probe error: exit 127)")
}

func TestGhidraRow(t *testing.T) {
	e := newDT(t)
	e.link("env")
	home := e.root + "/ghidra"
	headless := home + "/support/analyzeHeadless"
	e.ghidraHome = func() (string, error) { return home, nil }
	e.javaHome = func() (string, error) { return "/opt/j21", nil }

	e.tool(headless, `[ "$JAVA_HOME" = /opt/j21 ] && [ "$1" = -help ] && exit 0; exit 7`)
	wantRow(t, e.report(), "Ghidra headless", " AVAILABLE   "+headless)

	e.tool(headless, `echo "Headless Analyzer Usage: analyzeHeadless ..."; exit 1`) // usage banner, non-zero exit
	wantRow(t, e.report(), "Ghidra headless", " AVAILABLE   "+headless)

	e.tool(headless, `echo boom; exit 1`)
	wantRow(t, e.report(), "Ghidra headless", " UNUSABLE    "+headless+" (headless smoke test failed)")

	e.tool(headless, `echo "Headless Analyzer Usage"; sleep 5`) // banner printed but the bound ended it
	wantRow(t, e.report(), "Ghidra headless", " UNUSABLE    "+headless+" (headless smoke test failed)")

	e.tool(headless, `echo "Headless Analyzer Usage"; kill -9 $$`)
	wantRow(t, e.report(), "Ghidra headless", " UNUSABLE    "+headless+" (headless smoke test failed)")

	e.javaHome = func() (string, error) { return "", errors.New("no java") }
	e.tool(headless, "exit 0")
	wantRow(t, e.report(), "Ghidra headless", " UNUSABLE    "+headless+" (headless smoke test failed)")

	e.ghidraHome = func() (string, error) { return "", errors.New("none") }
	wantRow(t, e.report(), "Ghidra headless", " MISSING     (not on PATH nor known install dirs)")
}

func TestIlspyRow(t *testing.T) {
	e := newDT(t)
	runtime := e.root + "/runtime"
	if err := os.MkdirAll(runtime+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	// exits 0 only when DOTNET_ROOT is the runtime and diagnostics are off
	ilspy := e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && [ "$DOTNET_EnableDiagnostics" = 0 ] && exit 0; exit 1`)
	e.env["RSDD_DOTNET_ROOT"] = runtime
	rep := e.report()
	wantRow(t, rep, "ilspycmd", " AVAILABLE   "+ilspy+" (DOTNET_ROOT="+runtime+")")

	// RSDD_DOTNET_ROOT is fail-closed: unusable -> UNUSABLE and the shell's stderr line, no fallback to DOTNET_ROOT
	e.env["RSDD_DOTNET_ROOT"] = e.root + "/empty"
	e.env["DOTNET_ROOT"] = runtime
	out, er, code := e.run()
	wantRow(t, out, "ilspycmd", " UNUSABLE    "+ilspy+" (DOTNET_ROOT could not be resolved; install .NET 10+ or set RSDD_DOTNET_ROOT)")
	if want := "ERROR: RSDD_DOTNET_ROOT='" + e.root + "/empty' is set but ilspycmd --version failed with it (usability probe failed). Fix or unset RSDD_DOTNET_ROOT.\n"; er != want || code != 0 {
		t.Errorf("stderr = %q (exit %d), want %q", er, code, want)
	}

	// an ambient DOTNET_ROOT is tried, and a bad one falls through to the dotnet binary's directory
	delete(e.env, "RSDD_DOTNET_ROOT")
	wantRow(t, e.report(), "ilspycmd", " AVAILABLE   "+ilspy+" (DOTNET_ROOT="+runtime+")")
	e.env["DOTNET_ROOT"] = e.root + "/old-runtime"
	wantRow(t, e.report(), "ilspycmd", " UNUSABLE    "+ilspy+" (DOTNET_ROOT could not be resolved; install .NET 10+ or set RSDD_DOTNET_ROOT)")
	// derived: a dotnet binary whose directory holds shared/ ...
	delete(e.env, "DOTNET_ROOT")
	e.tool(runtime+"/dotnet", "exit 0")
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && exit 0; exit 1`)
	if err := os.Symlink(runtime+"/dotnet", e.bin+"/dotnet"); err != nil { // reached through a symlink: realpath
		t.Fatal(err)
	}
	wantRow(t, e.report(), "ilspycmd", " AVAILABLE   "+ilspy+" (DOTNET_ROOT="+runtime+")")
	// ... or whose sibling libexec does (the brew layout)
	if err := os.Remove(e.bin + "/dotnet"); err != nil {
		t.Fatal(err)
	}
	brewRT := e.root + "/cellar/libexec"
	if err := os.MkdirAll(brewRT+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	e.tool(e.root+"/cellar/bin/dotnet", "exit 0")
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+brewRT+`" ] && exit 0; exit 1`)
	if err := os.Symlink(e.root+"/cellar/bin/dotnet", e.bin+"/dotnet"); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "ilspycmd", " AVAILABLE   "+ilspy+" (DOTNET_ROOT="+brewRT+")")
	if err := os.Remove(e.bin + "/ilspycmd"); err != nil {
		t.Fatal(err)
	}
	wantRow(t, e.report(), "ilspycmd", " MISSING     (not on PATH nor known install dirs)")
}

func TestIlspyProbeWithoutTimeoutRunsDirect(t *testing.T) {
	e := newDT(t)
	runtime := e.root + "/runtime"
	if err := os.MkdirAll(runtime+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && exit 0; exit 1`)
	if err := os.Remove(e.bin + "/timeout"); err != nil {
		t.Fatal(err)
	}
	e.env["RSDD_DOTNET_ROOT"] = runtime
	wantRow(t, e.report(), "ilspycmd", " AVAILABLE   "+e.bin+"/ilspycmd (DOTNET_ROOT="+runtime+")")
}

func TestPwshDiagnosticsOff(t *testing.T) {
	e := newDT(t)
	e.tool("pwsh", `printf '%s\n' "${DOTNET_EnableDiagnostics:-unset}" >> "$RSDD_LOG"; exit 0`)
	e.tool("objdump", `printf '%s\n' "${DOTNET_EnableDiagnostics:-unset}" >> "$RSDD_LOG.other"; exit 0`)
	e.env["RSDD_LOG"] = e.root + "/log"
	e.env["DOTNET_EnableDiagnostics"] = "1"
	e.report()
	if b, _ := os.ReadFile(e.root + "/log"); string(b) != "0\n" {
		t.Errorf("pwsh saw DOTNET_EnableDiagnostics %q, want 0", b)
	}
	if b, _ := os.ReadFile(e.root + "/log.other"); string(b) != "1\n" {
		t.Errorf("another row saw DOTNET_EnableDiagnostics %q, want the ambient 1 (the switch is scoped to pwsh)", b)
	}
}

func TestPackageProbes(t *testing.T) {
	e := newDT(t)
	rep := e.report()
	wantRow(t, rep, "Hyperscan pkg-config", " MISSING     (libhs.pc not usable through pkg-config)")
	wantRow(t, rep, "pymupdf4llm", " MISSING     ("+e.home+"/.local/share/research-sdd-tools/venv — extract-pdf.sh Tier 1)")
	wantRow(t, rep, "circuitikz", " MISSING     (kpsewhich circuitikz.sty not found — install texlive-pictures)")
	wantRow(t, rep, "ezdxf", " MISSING     (python3 -c \"import ezdxf\" failed — pip install ezdxf)")

	e.tool("pkg-config", `[ "$1" = --modversion ] && [ "$2" = libhs ] || exit 1; echo "5.4.2"; echo "$PKG_CONFIG_PATH" > "$RSDD_LOG"`)
	e.env["RSDD_LOG"] = e.root + "/log"
	e.env["PKG_CONFIG_PATH"] = "/ambient"
	wantRow(t, e.report(), "Hyperscan pkg-config", " AVAILABLE   libhs 5.4.2 (command-local system pkg-config path)")
	if b, _ := os.ReadFile(e.root + "/log"); string(b) != "/ambient:"+e.root+"/pkgconfig\n" {
		t.Errorf("PKG_CONFIG_PATH = %q, want the ambient value then the system path", b)
	}
	e.tool("pkg-config", "exit 1")
	wantRow(t, e.report(), "Hyperscan pkg-config", " MISSING     (libhs.pc not usable through pkg-config)")
	e.env["PKG_CONFIG_BIN"] = e.tool(e.root+"/elsewhere/pkgc", `echo 1.0`) // PKG_CONFIG_BIN wins over PATH
	wantRow(t, e.report(), "Hyperscan pkg-config", " AVAILABLE   libhs 1.0 (command-local system pkg-config path)")

	e.tool("kpsewhich", `[ "$1" = circuitikz.sty ] && echo /tex/circuitikz.sty`)
	wantRow(t, e.report(), "circuitikz", " AVAILABLE   /tex/circuitikz.sty")
	e.tool("python3", `[ "$1" = -c ] && [ "$2" = "import ezdxf" ] && exit 0; exit 1`)
	wantRow(t, e.report(), "ezdxf", " AVAILABLE   "+e.bin+"/python3")
	e.tool("python3", "exit 1")
	wantRow(t, e.report(), "ezdxf", " MISSING     (python3 -c \"import ezdxf\" failed — pip install ezdxf)")

	venv := e.root + "/venv"
	e.env["RESEARCH_SDD_VENV"] = venv
	e.tool(venv+"/bin/python", `[ "$2" = "import pymupdf4llm" ] && exit 0; exit 1`)
	e.tool(venv+"/bin/ocrmypdf", "exit 0")
	e.tool(venv+"/bin/docling", "exit 0")
	rep = e.report()
	wantRow(t, rep, "pymupdf4llm", " AVAILABLE   "+venv+"/bin/python")
	wantRow(t, rep, "ocrmypdf", " AVAILABLE   "+venv+"/bin/ocrmypdf")
	wantRow(t, rep, "docling", " AVAILABLE   "+venv+"/bin/docling")
	e.tool(venv+"/bin/python", "exit 1") // the import fails: the module is not there
	wantRow(t, e.report(), "pymupdf4llm", " MISSING     ("+venv+" — extract-pdf.sh Tier 1)")
}

func TestBinwalkNote(t *testing.T) {
	e := newDT(t)
	v3 := `if [ "${1:-}" = --version ]; then echo "binwalk 3.1.0"; else echo "Usage: binwalk [OPTIONS] [FILE_NAME]"; fi`
	v2 := `echo "Binwalk v2.3.3"`
	count := func(rep string) int { return strings.Count(rep, "\n  binwalk                ") }

	e.tool("binwalk", v3)
	rep := e.report()
	if !strings.Contains(rep, fmt.Sprintf("  %-22s WARN        binwalk 3.1.0: corroborate-firmware supports only binwalk major 2\n", "binwalk")) || count(rep) != 2 {
		t.Errorf("3.x must be AVAILABLE and WARNed:\n%s", rep)
	}
	e.tool("binwalk", v2)
	if rep = e.report(); strings.Contains(rep, "WARN") || count(rep) != 1 {
		t.Errorf("2.x must not WARN:\n%s", rep)
	}
	e.tool("binwalk", "echo no version here")
	if rep = e.report(); !strings.Contains(rep, fmt.Sprintf("  %-22s WARN        version unknown (corroborate-firmware supports only binwalk major 2)\n", "binwalk")) {
		t.Errorf("unknown version must WARN:\n%s", rep)
	}
	// the LAST "binwalk <version>" of a line wins (sed greedy), and the first matching line is used
	e.tool("binwalk", `echo "x"; echo "Binwalk v2.1 and binwalk 3.0.1 built"; echo "binwalk 9"`)
	if rep = e.report(); !strings.Contains(rep, "binwalk 3.0.1: corroborate") {
		t.Errorf("greedy last-on-line version expected:\n%s", rep)
	}
	// an explicit RSDD_BINWALK is the binary that is version-checked, and it can be non-executable
	e.tool("binwalk", v2)
	e.env["RSDD_BINWALK"] = e.tool(e.root+"/bw3/binwalk", v3)
	if rep = e.report(); !strings.Contains(rep, "binwalk 3.1.0: corroborate") {
		t.Errorf("RSDD_BINWALK must be the checked binary:\n%s", rep)
	}
	e.env["RSDD_BINWALK"] = e.root + "/no-such-binwalk"
	if rep = e.report(); !strings.Contains(rep, fmt.Sprintf("  %-22s WARN        RSDD_BINWALK=%s/no-such-binwalk is not executable; corroborate-firmware will refuse it\n", "binwalk", e.root)) {
		t.Errorf("non-executable RSDD_BINWALK must WARN:\n%s", rep)
	}
	// a present but non-executable PATH-resolved binwalk is silent when RSDD_BINWALK is unset
	delete(e.env, "RSDD_BINWALK")
	if err := os.Chmod(e.bin+"/binwalk", 0o644); err != nil {
		t.Fatal(err)
	}
	if rep = e.report(); strings.Contains(rep, "WARN") {
		t.Errorf("non-executable resolved binwalk must stay silent:\n%s", rep)
	}
	// no binwalk at all: the note adds nothing
	if err := os.Remove(e.bin + "/binwalk"); err != nil {
		t.Fatal(err)
	}
	if rep = e.report(); strings.Contains(rep, "WARN") {
		t.Errorf("absent binwalk must not WARN:\n%s", rep)
	}
}

func TestChildSeesTheCallersEnvironment(t *testing.T) {
	e := newDT(t)
	e.tool("objdump", `printf '%s|%s\n' "$PATH" "$TMPDIR" > "$RSDD_LOG"`)
	e.env["RSDD_LOG"] = e.root + "/log"
	e.env["TMPDIR"] = e.root + "/tmp"
	e.report()
	if b, _ := os.ReadFile(e.root + "/log"); string(b) != e.bin+"|"+e.root+"/tmp\n" {
		t.Errorf("probe child saw %q", b)
	}
}

func TestCacheLocationAndModes(t *testing.T) {
	e := newDT(t)
	delete(e.env, "RESEARCH_TOOLS_CACHE")
	stdout, _, code := e.run("--quiet")
	want := e.home + "/.cache/research-sdd/tool-capabilities.txt"
	if code != 0 || stdout != "tool capability report cached → "+want+"\n" {
		t.Fatalf("quiet: exit %d stdout %q", code, stdout)
	}
	if b, err := os.ReadFile(want); err != nil || !strings.HasPrefix(string(b), "== Research-SDD tool capability report ==\n") || !strings.HasSuffix(string(b), "MISSING means not detected.\n") {
		t.Fatalf("cache file: %v %q", err, b)
	}
	e.env["XDG_CACHE_HOME"] = e.root + "/xdg"
	if _, _, code = e.run("--quiet"); code != 0 {
		t.Fatalf("xdg exit %d", code)
	}
	if _, err := os.Stat(e.root + "/xdg/research-sdd/tool-capabilities.txt"); err != nil {
		t.Errorf("XDG_CACHE_HOME ignored: %v", err)
	}
	e.env["RESEARCH_TOOLS_CACHE"] = e.root + "/fromenv/c.txt"
	if _, _, code = e.run("--quiet"); code != 0 {
		t.Fatalf("env exit %d", code)
	}
	if _, err := os.Stat(e.root + "/fromenv/c.txt"); err != nil {
		t.Errorf("RESEARCH_TOOLS_CACHE ignored: %v", err)
	}
	// --cache wins over the environment, and a relative path is anchored at the working directory
	stdout, _, code = e.run("--cache", "rel/dir/c.txt")
	if code != 0 {
		t.Fatalf("rel exit %d", code)
	}
	b, err := os.ReadFile(e.cwd + "/rel/dir/c.txt")
	if err != nil || stdout != string(b) {
		t.Errorf("non-quiet stdout must equal the cache file: %v\nstdout %q\ncache  %q", err, stdout, b)
	}
}

func TestReportHeader(t *testing.T) {
	e := newDT(t)
	e.tool("uname", `[ "$1" = -srm ] && echo "Fake 1.2 mach"`)
	want := "host: Fake 1.2 mach · date: 2026-11-02T12:30:45Z · brew: " + e.brew + "\n"
	if rep := e.report(); !strings.Contains(rep, want) {
		t.Errorf("header\n got %q\nwant it to contain %q", strings.SplitN(rep, "\n", 4)[1], want)
	}
}

func TestCacheErrors(t *testing.T) {
	e := newDT(t)
	if err := os.WriteFile(e.root+"/afile", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ cache, want string }{
		{e.root + "/afile/sub/c.txt", "detect-tools.sh: cannot create cache directory: " + e.root + "/afile/sub\n"},
		{e.root, "detect-tools.sh: cannot write cache file: " + e.root + "\n"},
	} {
		e.env["RESEARCH_TOOLS_CACHE"] = c.cache
		stdout, er, code := e.run("--quiet")
		if code != 1 || er != c.want || stdout != "" {
			t.Errorf("%s: exit %d stderr %q stdout %q, want exit 1 / %q / empty", c.cache, code, er, stdout, c.want)
		}
	}
}

func TestDirname(t *testing.T) {
	for in, want := range map[string]string{"a": ".", "/a": "/", "a/b": "a", "a/b/": "a", "/": "/", "a//b//": "a", "/a/b": "/a", "./c": "."} {
		if got := dirname(in); got != want {
			t.Errorf("dirname(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRequire(t *testing.T) {
	e := newDT(t)
	e.tool("objdump", "exit 0")
	e.tool("nm", "exit 1")
	cases := []struct {
		args       []string
		code       int
		stderr     string
		wantReport bool
	}{
		{[]string{"--require", "objdump"}, 0, "", true},
		{[]string{"--require", "ghidra"}, 1, "REQUIRE FAILED [ghidra] MISSING — install it and re-run detect-tools.sh\n", true},
		{[]string{"--require", "nm"}, 1, "REQUIRE FAILED [nm] UNUSABLE — found but smoke test failed (present but broken is not usable)\n", true},
		{[]string{"--quiet", "--require", "nm"}, 1, "REQUIRE FAILED [nm] UNUSABLE — found but smoke test failed (present but broken is not usable)\n", false},
		// every named tool is judged, in order, and one failure fails the run
		{[]string{"--require", "objdump,nm,ghidra"}, 1, "REQUIRE FAILED [nm] UNUSABLE — found but smoke test failed (present but broken is not usable)\nREQUIRE FAILED [ghidra] MISSING — install it and re-run detect-tools.sh\n", true},
		// one trailing comma is dropped, as read -ra does
		{[]string{"--require", "objdump,"}, 0, "", true},
		// an unknown name ends the run with 2 after the earlier tools were judged
		{[]string{"--require", "nm,bogus,ghidra"}, 2, "REQUIRE FAILED [nm] UNUSABLE — found but smoke test failed (present but broken is not usable)\ndetect-tools.sh: --require: unknown tool \"bogus\" — not in known set\n", true},
		{[]string{"--require", "objdump,,nm"}, 2, "detect-tools.sh: --require: unknown tool \"\" — not in known set\n", true},
		{[]string{"--require", "objdump,,"}, 2, "detect-tools.sh: --require: unknown tool \"\" — not in known set\n", true},
		{[]string{"--require", ","}, 2, "detect-tools.sh: --require: unknown tool \"\" — not in known set\n", true},
		// only the first line of the list is read
		{[]string{"--require", "objdump\nbogus"}, 0, "", true},
		// the last --require wins
		{[]string{"--require", "nm", "--require", "objdump"}, 0, "", true},
	}
	for _, c := range cases {
		stdout, er, code := e.run(c.args...)
		if code != c.code || er != c.stderr {
			t.Errorf("%q: exit %d stderr %q, want exit %d stderr %q", c.args, code, er, c.code, c.stderr)
		}
		if has := strings.HasPrefix(stdout, "== Research-SDD tool capability report =="); has != c.wantReport {
			t.Errorf("%q: report on stdout = %v, want %v", c.args, has, c.wantReport)
		}
	}
}

func TestRequireProbeFailedIsNotAvailable(t *testing.T) {
	e := newDT(t)
	e.tool("readelf", "sleep 5")
	_, er, code := e.run("--require", "readelf")
	if want := "REQUIRE FAILED [readelf] could not determine — probe failed (timeout or environment error); treating as unavailable\n"; code != 1 || er != want {
		t.Fatalf("exit %d stderr %q, want exit 1 %q", code, er, want)
	}
}

func TestRequireWritesTheCacheBeforeJudging(t *testing.T) {
	e := newDT(t)
	if _, _, code := e.run("--quiet", "--require", "ghidra"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if b, err := os.ReadFile(e.root + "/cache.txt"); err != nil || !strings.Contains(string(b), "Ghidra headless") {
		t.Fatalf("cache not written before the gate: %v", err)
	}
}

func TestRequireLabelsAliasesShareARow(t *testing.T) {
	e := newDT(t)
	e.tool("r2", "exit 0")
	e.javaHome = func() (string, error) { return "/j", nil }
	for _, name := range []string{"r2", "radare2"} {
		if _, er, code := e.run("--require", name); code != 0 {
			t.Errorf("--require %s: exit %d %q", name, code, er)
		}
	}
	for _, name := range []string{"java", "java21", "javap"} {
		if _, er, code := e.run("--require", name); code != 0 {
			t.Errorf("--require %s: exit %d %q", name, code, er)
		}
	}
}

// Every name --require accepts must find its row in the report: a label without a row would pass the gate as
// "internal error" only after the fact, so it is pinned here for all of them at once.
func TestEveryRequireLabelHasARow(t *testing.T) {
	e := newDT(t)
	rep := e.report()
	seen := map[string]bool{}
	for name, label := range requireLabels {
		if rowOf(rep, label) == "" {
			t.Errorf("--require %s: no report row labelled %q", name, label)
		}
		seen[label] = true
	}
	// and every report row is reachable through some name
	for _, ln := range strings.Split(rep, "\n") {
		if strings.HasPrefix(ln, "  ") && !strings.HasPrefix(ln, "  Note") {
			label := strings.TrimRight(ln[2:24], " ")
			if !seen[label] && label != "Hyperscan pkg-config" {
				t.Errorf("report row %q has no --require name", label)
			}
		}
	}
}

func TestStatusOf(t *testing.T) {
	rep := strings.Join([]string{
		"  binwalk                WARN        version unknown",
		"  binwalk                AVAILABLE   /x/binwalk",
		"  nm                     MISSING     (not on PATH, was AVAILABLE once)",
		"  strings                UNUSABLE    /x",
		"  xnm                    PROBE_FAILED /x",
	}, "\n")
	for label, want := range map[string]string{"binwalk": "AVAILABLE", "nm": "MISSING", "strings": "UNUSABLE", "xnm": "PROBE_FAILED", "none": ""} {
		if got := statusOf(rep, label); got != want {
			t.Errorf("statusOf(%q) = %q, want %q", label, got, want)
		}
	}
}

func TestUsage(t *testing.T) {
	e := newDT(t)
	for _, args := range [][]string{{"--bogus"}, {"--require"}, {"--require", ""}, {"--quiet", "extra"}, {"--cache", "x", "--bogus"}} {
		stdout, er, code := e.run(args...)
		if code != 2 || stdout != "" || er != "usage: detect-tools.sh [--cache <file>] [--quiet] [--require <tool>[,<tool>...]]\n" {
			t.Errorf("%q: exit %d stdout %q stderr %q", args, code, stdout, er)
		}
	}
	if _, _, code := e.run("--cache"); code != 1 {
		t.Errorf("--cache without a path: exit %d, want 1", code)
	}
	if _, er, code := e.run("--cache", ""); code != 1 || !strings.Contains(er, "--cache") {
		t.Errorf("--cache '': exit %d stderr %q, want 1 naming the flag", code, er)
	}
	// the shim names itself with --prog (first argument only); messages use its path or its basename
	if _, er, code := e.run("--prog", "/kit/toolbelt/detect-tools.sh", "--bogus"); code != 2 || er != "usage: /kit/toolbelt/detect-tools.sh [--cache <file>] [--quiet] [--require <tool>[,<tool>...]]\n" {
		t.Errorf("--prog usage: exit %d %q", code, er)
	}
	if _, er, code := e.run("--prog", "/kit/toolbelt/dt.sh", "--require", "bogus"); code != 2 || !strings.HasPrefix(er, "dt.sh: --require: unknown tool") {
		t.Errorf("--prog basename: exit %d %q", code, er)
	}
	if _, er, code := e.run("--bogus", "--prog", "x"); code != 2 || !strings.HasPrefix(er, "usage: detect-tools.sh ") {
		t.Errorf("--prog after another argument is not special: exit %d %q", code, er)
	}
}

func TestCommandIsRegistered(t *testing.T) {
	var out, er bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &er, Env: func(string) string { return "" },
		Clock: func() time.Time { return dtClock }, Cwd: t.TempDir()}
	if code := cli.Run(Commands, []string{"install", "detect-tools", "--bogus"}, s); code != 2 || !strings.Contains(er.String(), "usage: detect-tools.sh") {
		t.Fatalf("rsdd install detect-tools --bogus: exit %d stderr %q", code, er.String())
	}
}
