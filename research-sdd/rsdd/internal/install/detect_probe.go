package install

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// The run-probes of toolbelt/lib/tool-env.sh (rsdd_run_probe, rsdd_capture_probe, rsdd_probe_ghidra,
// rsdd_probe_java_jar, rsdd_file_sha256, rsdd_pkg_config, rsdd_resolve_dotnet_root). core/probe ports the
// resolvers only and leaves these to their one consumer, detect-tools. They keep the shell's contract: the tool
// runs under the real timeout(1), so a probe killed by the bound reads 124 and a missing timeout reads 127, which
// the report tells apart from UNUSABLE.

// Return codes the report keys on, as the shell functions return them.
const (
	rcTimeout = 124 // timeout(1) stopped the probe
	rcKilled  = 137 // the probe was SIGKILLed
	rcNoTool  = 127 // the probe machinery (timeout, unzip) is not there
)

// detector probes one environment and working directory.
type detector struct {
	p       *probe.Prober
	environ []string
	env     map[string]string
	cwd     string
	root    string // prefix of the fixed host paths (/usr/bin/..); empty except in tests
	// javaHome and ghidraHome are the resolvers the report and the Ghidra probe consult, replaceable in tests.
	javaHome, ghidraHome func() (string, error)
}

func newDetector(environ []string, cwd string) *detector {
	env := make(map[string]string, len(environ))
	for _, kv := range environ {
		if k, v, ok := strings.Cut(kv, "="); ok {
			env[k] = v
		}
	}
	p := probe.New(environ, cwd)
	return &detector{p: p, environ: environ, env: env, cwd: cwd, javaHome: p.JavaHome, ghidraHome: p.GhidraHome}
}

// get is "${key:-}".
func (d *detector) get(key string) string { return d.env[key] }

// fixed is a host path the shell hardcodes (/usr/bin/r2); tests relocate it under root.
func (d *detector) fixed(path string) string { return d.root + path }

// abs anchors a relative path at the working directory.
func (d *detector) abs(path string) string {
	if path == "" || strings.HasPrefix(path, "/") {
		return path
	}
	return d.cwd + "/" + path
}

// probeTimeout is "${RSDD_PROBE_TIMEOUT:-10}".
func (d *detector) probeTimeout() string {
	if t := d.get("RSDD_PROBE_TIMEOUT"); t != "" {
		return t
	}
	return "10"
}

// withEnv is environ with each KEY=value of extra replacing any earlier KEY (the shell's `KEY=v cmd`).
func withEnv(environ []string, extra ...string) []string {
	if len(extra) == 0 {
		return environ
	}
	drop := map[string]bool{}
	for _, kv := range extra {
		k, _, _ := strings.Cut(kv, "=")
		drop[k] = true
	}
	var out []string
	for _, kv := range environ {
		if k, _, _ := strings.Cut(kv, "="); !drop[k] {
			out = append(out, kv)
		}
	}
	return append(out, extra...)
}

// exitCode is the shell's `$?` for a finished command: 128+N for a signal, 126 for a program that did not start.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return 126
	}
	if c := ee.ExitCode(); c != -1 { // -1: killed by a signal
		return c
	}
	if ws, ok := ee.Sys().(interface{ Signal() syscall.Signal }); ok {
		return 128 + int(ws.Signal())
	}
	return 255
}

// command is argv in the detector's environment and working directory.
func (d *detector) command(extraEnv []string, argv ...string) *exec.Cmd {
	c := exec.Command(argv[0], argv[1:]...)
	c.Dir, c.Env = d.cwd, withEnv(d.environ, extraEnv...)
	return c
}

// runProbe is rsdd_run_probe: `timeout T path args` with both streams dropped. 1 when path is not executable,
// 127 when timeout(1) is not on PATH, else timeout's own status (124 = the bound, 137 = SIGKILL).
func (d *detector) runProbe(extraEnv []string, timeout, path string, args ...string) int {
	if !d.p.IsExec(path) {
		return 1
	}
	tb, err := d.p.LookPath("timeout")
	if err != nil {
		return rcNoTool
	}
	return exitCode(d.command(extraEnv, append([]string{tb, timeout, d.abs(path)}, args...)...).Run())
}

// captureProbe is rsdd_capture_probe: the same under timeout(1), stdout and stderr merged in order and the
// trailing newlines cut (`$(...)`). 1 when path is neither on PATH nor executable.
func (d *detector) captureProbe(stdin io.Reader, timeout, path string, args ...string) (string, int) {
	if _, err := d.p.LookPath(path); err != nil && !d.p.IsExec(path) {
		return "", 1
	}
	tb, err := d.p.LookPath("timeout")
	if err != nil {
		return "", rcNoTool
	}
	var buf bytes.Buffer
	c := d.command(nil, append([]string{tb, timeout, path}, args...)...)
	c.Stdin, c.Stdout, c.Stderr = stdin, &buf, &buf
	rc := exitCode(c.Run())
	return strings.TrimRight(buf.String(), "\n"), rc
}

// probeGhidra is rsdd_probe_ghidra: analyzeHeadless -help under a usable Java answers 0, or (when the bound or a
// kill did not end it) prints its usage banner.
func (d *detector) probeGhidra(home string) bool {
	java, err := d.javaHome()
	if err != nil {
		return false
	}
	headless := home + "/support/analyzeHeadless"
	if !d.p.IsExec(headless) {
		return false
	}
	out, rc := d.captureProbe(nil, d.probeTimeout(), "env", "JAVA_HOME="+java, headless, "-help")
	switch {
	case rc == 0:
		return true
	case rc == rcTimeout || rc == rcKilled:
		return false
	}
	return strings.Contains(out, "Headless Analyzer Usage")
}

// jarEntries is the class each decompiler jar must hold (rsdd_probe_java_jar).
var jarEntries = map[string]string{
	"vineflower": "org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class",
	"cfr":        "org/benf/cfr/reader/Main.class",
	"procyon":    "com/strobel/decompiler/DecompilerDriver.class",
}

// probeJar is rsdd_probe_java_jar: 0 valid, 1 not valid, 2 unknown name, 127 unzip is not on PATH. A timeout of
// either unzip step reads 1 (the shell collapses it), which is why a jar probe never reports PROBE_FAILED for it.
func (d *detector) probeJar(name, jar string) int {
	if fi, err := os.Stat(d.abs(jar)); err != nil || fi.Size() == 0 {
		return 1
	}
	entry, ok := jarEntries[name]
	if !ok {
		return 2
	}
	unzip, err := d.p.LookPath("unzip")
	if err != nil {
		return rcNoTool
	}
	t := d.probeTimeout()
	if d.runProbe(nil, t, unzip, "-tqq", jar) != 0 {
		return 1
	}
	listing, rc := d.captureProbe(nil, t, unzip, "-Z1", jar, entry)
	if rc != 0 || listing != entry {
		return 1
	}
	return 0
}

// fileSHA256 is rsdd_file_sha256: the digest sha256sum prints for the file on its stdin (never a positional name,
// kit issue #2190), ok false when sha256sum is missing or fails.
func (d *detector) fileSHA256(file string) (string, bool) {
	sha, err := d.p.LookPath("sha256sum")
	if err != nil {
		return "", false
	}
	f, err := os.Open(d.abs(file))
	if err != nil {
		return "", false
	}
	defer f.Close()
	out, rc := d.captureProbe(f, d.probeTimeout(), sha)
	if rc != 0 {
		return "", false
	}
	digest, _, _ := strings.Cut(out, " ")
	return digest, true
}

// pkgConfigVersion is `rsdd_pkg_config --modversion pkg 2>/dev/null`: PKG_CONFIG_BIN or pkg-config on PATH, run
// with PKG_CONFIG_PATH extended by the system directories. ok is the shell's rc == 0.
func (d *detector) pkgConfigVersion(pkg string) (string, bool) {
	bin := d.get("PKG_CONFIG_BIN")
	if bin == "" {
		bin, _ = d.p.LookPath("pkg-config")
	}
	if !d.p.IsExec(bin) {
		return "", false
	}
	sys, _ := d.p.SystemPkgConfigPath()
	combined := d.get("PKG_CONFIG_PATH")
	if combined != "" {
		combined += ":"
	}
	var out bytes.Buffer
	c := d.command([]string{"PKG_CONFIG_PATH=" + combined + sys}, d.abs(bin), "--modversion", pkg)
	c.Stdout = &out
	if c.Run() != nil {
		return "", false
	}
	return strings.TrimRight(out.String(), "\n"), true
}

// dotnetProbe is _rsdd_dotnet_probe: root holds shared/Microsoft.NETCore.App and `ilspycmd --version` exits 0 with
// DOTNET_ROOT=root, under timeout(1) when it exists. Diagnostics are off so a killed probe leaves no IPC files.
func (d *detector) dotnetProbe(root, ilspy string) bool {
	if fi, err := os.Stat(d.abs(root + "/shared/Microsoft.NETCore.App")); err != nil || !fi.IsDir() {
		return false
	}
	extra := []string{"DOTNET_EnableDiagnostics=0", "DOTNET_ROOT=" + root}
	argv := []string{d.abs(ilspy), "--version"}
	if tb, err := d.p.LookPath("timeout"); err == nil && d.p.IsExec(tb) {
		argv = append([]string{tb, d.probeTimeout()}, argv...)
	}
	return d.command(extra, argv...).Run() == nil
}

// dotnetRoot is rsdd_resolve_dotnet_root: RSDD_DOTNET_ROOT (fail closed, with the shell's stderr message),
// then the ambient DOTNET_ROOT (falls through when unusable), then the dotnet binary's directory and its
// libexec sibling. ok is the shell's rc == 0; msg is what the shell wrote to stderr.
func (d *detector) dotnetRoot(ilspy string) (root, msg string, ok bool) {
	if r := d.get("RSDD_DOTNET_ROOT"); r != "" {
		if d.dotnetProbe(r, ilspy) {
			return r, "", true
		}
		return "", "ERROR: RSDD_DOTNET_ROOT='" + r + "' is set but ilspycmd --version failed with it (usability probe failed). Fix or unset RSDD_DOTNET_ROOT.\n", false
	}
	if r := d.get("DOTNET_ROOT"); r != "" && d.dotnetProbe(r, ilspy) {
		return r, "", true
	}
	bin, _ := d.p.LookPath("dotnet")
	if !d.p.IsExec(bin) {
		return "", "", false
	}
	real, err := filepath.EvalSymlinks(d.abs(bin))
	if err != nil {
		real = d.abs(bin)
	}
	dir := filepath.Dir(real)
	for _, c := range []string{dir, filepath.Dir(dir) + "/libexec"} {
		if d.dotnetProbe(c, ilspy) {
			return c, "", true
		}
	}
	return "", "", false
}
