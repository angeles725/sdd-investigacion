package install

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// reportCtx carries one report run: the text built so far and what the shell wrote to stderr meanwhile.
type reportCtx struct {
	d    *detector
	b    strings.Builder
	errw *bytes.Buffer
	brew string
	now  time.Time
}

func (r *reportCtx) line(format string, a ...any) { fmt.Fprintf(&r.b, format+"\n", a...) }

// brewBin is "${BREW:+$BREW<suffix>}": empty without a brew prefix.
func (r *reportCtx) brewBin(suffix string) string {
	if r.brew == "" {
		return ""
	}
	return r.brew + suffix
}

// exists is `[ -e path ]`.
func (r *reportCtx) exists(path string) bool {
	_, err := os.Stat(r.d.abs(path))
	return err == nil
}

// globMeta are the characters that make a candidate a shell pattern.
const globMeta = "*?["

// resolve is detect-tools' resolve(): PATH first, then each candidate, which the shell word-splits and
// glob-expands (a pattern that matches nothing stays literal). ok is the shell's rc == 0.
func (r *reportCtx) resolve(cmd string, cands ...string) (string, bool) {
	if p, err := r.d.p.LookPath(cmd); err == nil && p != "" {
		return p, true
	}
	for _, cand := range cands {
		for _, f := range strings.Fields(cand) {
			matches := []string{f}
			if strings.ContainsAny(f, globMeta) {
				if g, err := filepath.Glob(r.d.abs(f)); err == nil && len(g) > 0 {
					matches = g
					if !strings.HasPrefix(f, "/") {
						matches = make([]string, len(g))
						for i, m := range g {
							matches[i] = strings.TrimPrefix(m, r.d.cwd+"/")
						}
					}
				}
			}
			for _, g := range matches {
				if r.exists(g) {
					return g, true
				}
			}
		}
	}
	return "", false
}

// rowOpts selects the python row's bounds and the pwsh row's environment.
type rowOpts struct {
	extraEnv []string
	timeout  string // probe timeout; "" is RSDD_PROBE_TIMEOUT
	python   bool   // python_row: also reads 137 as a probe failure, "entrypoint" wording
}

// row is `row "<label>" "<cmd>" "<smoke-arg>" [candidates...]`.
func (r *reportCtx) row(o rowOpts, label, cmd, smoke string, cands ...string) {
	path, ok := r.resolve(cmd, cands...)
	if !ok {
		r.line("  %-22s MISSING     (not on PATH nor known install dirs)", label)
		return
	}
	t := o.timeout
	if t == "" {
		t = r.d.probeTimeout()
	}
	rc := r.d.runProbe(o.extraEnv, t, path, smoke)
	failed := rc == rcTimeout || rc == rcNoTool || (o.python && rc == rcKilled)
	switch {
	case rc == 0:
		r.line("  %-22s AVAILABLE   %s", label, path)
	case failed:
		r.line("  %-22s PROBE_FAILED %s (probe error: exit %d)", label, path, rc)
	case o.python:
		r.line("  %-22s UNUSABLE    %s (entrypoint smoke test failed)", label, path)
	default:
		r.line("  %-22s UNUSABLE    %s (smoke test failed)", label, path)
	}
}

// jarRow is jarrow(): a decompiler jar is AVAILABLE only when it validates AND its digest can be read.
func (r *reportCtx) jarRow(label, name string) {
	jar, err := r.d.p.JavaJar(name)
	if err != nil {
		r.line("  %-22s MISSING     (jar not found; set the matching env var)", label)
		return
	}
	rc := r.d.probeJar(name, jar)
	digest, shaOK := "", false
	if rc == 0 {
		digest, shaOK = r.d.fileSHA256(jar)
	}
	switch {
	case rc == 0 && shaOK:
		r.line("  %-22s AVAILABLE   %s (sha256=%s)", label, jar, digest)
	case rc == rcNoTool:
		r.line("  %-22s PROBE_FAILED %s (probe error: exit %d)", label, jar, rc)
	default:
		r.line("  %-22s UNUSABLE    %s (archive structure/digest validation failed)", label, jar)
	}
}

func (r *reportCtx) ghidraRow() {
	home, err := r.d.ghidraHome()
	if err != nil {
		r.line("  %-22s MISSING     (not on PATH nor known install dirs)", "Ghidra headless")
		return
	}
	if r.d.probeGhidra(home) {
		r.line("  %-22s AVAILABLE   %s", "Ghidra headless", home+"/support/analyzeHeadless")
		return
	}
	r.line("  %-22s UNUSABLE    %s (headless smoke test failed)", "Ghidra headless", home+"/support/analyzeHeadless")
}

func (r *reportCtx) javaRows() {
	if home, err := r.d.javaHome(); err == nil {
		r.line("  %-22s AVAILABLE   %s", "Java 21", home+"/bin/java")
		r.line("  %-22s AVAILABLE   %s", "javap 21", home+"/bin/javap")
		return
	}
	// The resolver collapses a probe timeout into "not found"; a secondary probe of any java on PATH tells a
	// timed-out probe (PROBE_FAILED) from a missing install.
	bin, _ := r.d.p.LookPath("java")
	rc := 0
	if bin != "" {
		rc = r.d.runProbe(nil, r.d.probeTimeout(), bin, "-version")
	}
	if rc == rcTimeout || rc == rcNoTool || rc == rcKilled {
		r.line("  %-22s PROBE_FAILED %s (probe error: exit %d)", "Java 21", bin, rc)
		r.line("  %-22s PROBE_FAILED %s (probe error: exit %d)", "javap 21", bin, rc)
		return
	}
	r.line("  %-22s MISSING     (usable Java 21 + javap not found)", "Java 21")
	r.line("  %-22s MISSING     (usable Java 21 + javap not found)", "javap 21")
}

func (r *reportCtx) ilspyRow() {
	ilspy, err := r.d.p.ILSpy()
	if err != nil {
		r.line("  %-22s MISSING     (not on PATH nor known install dirs)", "ilspycmd")
		return
	}
	root, msg, ok := r.d.dotnetRoot(ilspy)
	r.errw.WriteString(msg)
	if ok && root != "" {
		r.line("  %-22s AVAILABLE   %s (DOTNET_ROOT=%s)", "ilspycmd", ilspy, root)
		return
	}
	r.line("  %-22s UNUSABLE    %s (DOTNET_ROOT could not be resolved; install .NET 10+ or set RSDD_DOTNET_ROOT)", "ilspycmd", ilspy)
}

var binwalkVersion = regexp.MustCompile(`^.*[Bb]inwalk v?([0-9][^ ]*).*$`)

// binwalkNote is binwalk_note: corroborate-firmware supports only binwalk major 2.
func (r *reportCtx) binwalkNote() {
	bw := r.d.get("RSDD_BINWALK")
	if bw == "" {
		var ok bool
		if bw, ok = r.resolve("binwalk", r.d.fixed("/usr/bin/binwalk"), r.brewBin("/bin/binwalk")); !ok {
			return
		}
	}
	if !r.d.p.IsExec(bw) {
		if r.d.get("RSDD_BINWALK") != "" {
			r.line("  %-22s WARN        RSDD_BINWALK=%s is not executable; corroborate-firmware will refuse it", "binwalk", bw)
		}
		return
	}
	var out bytes.Buffer
	for _, flag := range []string{"--version", "--help"} {
		c := r.d.command(nil, r.d.abs(bw), flag)
		c.Stdout, c.Stderr = &out, &out
		_ = c.Run() // the shell ignores the status: only the text is read
	}
	ver := ""
	for _, ln := range strings.Split(out.String(), "\n") {
		if m := binwalkVersion.FindStringSubmatch(ln); m != nil {
			ver = m[1]
			break
		}
	}
	switch major, _, _ := strings.Cut(ver, "."); {
	case ver == "":
		r.line("  %-22s WARN        version unknown (corroborate-firmware supports only binwalk major 2)", "binwalk")
	case major != "2":
		r.line("  %-22s WARN        binwalk %s: corroborate-firmware supports only binwalk major 2", "binwalk", ver)
	}
}

func (r *reportCtx) uname() string {
	u, err := r.d.p.LookPath("uname")
	if err != nil {
		return ""
	}
	var out bytes.Buffer
	c := r.d.command(nil, r.d.abs(u), "-srm")
	c.Stdout = &out
	_ = c.Run()
	return strings.TrimRight(out.String(), "\n")
}
