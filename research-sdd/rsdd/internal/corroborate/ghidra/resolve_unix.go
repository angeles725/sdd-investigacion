//go:build unix

//lint:file-ignore ST1005 the messages are the legacy driver's, kept byte for byte (parity)

package ghidra

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// tools are the canonical host locations the run needs.
type tools struct {
	ghidraHome string // directory holding support/analyzeHeadless
	javaHome   string // JDK 21+ home
	java       string // javaHome/bin/java, canonical
	bwrap      string // Bubblewrap launcher, canonical
	exporter   string // CuratedEvidenceExporter.java
}

// exporterRel is the exporter's place inside the kit.
const exporterRel = "toolbelt/ghidra/CuratedEvidenceExporter.java"

// abs reads a relative path against the injected working directory, without cleaning it.
func (j *job) abs(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return j.s.Cwd + "/" + p
}

// safeFile is `realpath -e` plus "regular and executable".
func (j *job) safeFile(p string) (string, bool) {
	if p == "" {
		return "", false
	}
	real, err := filepath.EvalSymlinks(j.abs(p))
	if err != nil {
		return "", false
	}
	fi, err := os.Stat(real)
	if err != nil || !fi.Mode().IsRegular() || !canExec(real) {
		return "", false
	}
	return real, true
}

// resolveTools is what corroborate-ghidra.sh did before handing over to Python: find Ghidra and a JDK 21+,
// canonicalise them, and pick the Java and Bubblewrap launchers (RSDD_BWRAP, else the one on PATH) and the
// exporter script. Every failure is one typed line and exit 2.
func (j *job) resolveTools() (tools, error) {
	var t tools
	p := probe.New(j.s.Environ(), j.s.Cwd)
	home, err := p.GhidraHome()
	if err != nil {
		return t, errors.New("Ghidra unavailable")
	}
	jdk, err := p.JavaHome()
	if err != nil {
		return t, errors.New("Java 21 unavailable")
	}
	if t.ghidraHome, err = filepath.EvalSymlinks(j.abs(home)); err != nil {
		return t, errors.New("Ghidra unavailable")
	}
	if t.javaHome, err = filepath.EvalSymlinks(j.abs(jdk)); err != nil {
		return t, errors.New("Java 21 unavailable")
	}
	var ok bool
	if t.java, ok = j.safeFile(t.javaHome + "/bin/java"); !ok {
		return t, errors.New("unsafe Java executable")
	}
	bw := j.s.Env("RSDD_BWRAP")
	if bw == "" {
		bw, _ = p.LookPath("bwrap")
	}
	if t.bwrap, ok = j.safeFile(bw); !ok {
		return t, errors.New("Bubblewrap unavailable")
	}
	switch {
	case j.cfg.exporter != "":
		t.exporter = j.abs(j.cfg.exporter)
	case j.cfg.toolbelt != "":
		t.exporter = j.abs(j.cfg.toolbelt) + "/ghidra/CuratedEvidenceExporter.java"
	default:
		path, _, err := kit.ResolveKitScript(exporterRel, kit.Getenv(j.s.Env))
		if err != nil {
			return t, errors.New("cannot resolve the exporter (pass --toolbelt DIR or set RESEARCH_SDD_KIT): " + err.Error())
		}
		t.exporter = path
	}
	return t, nil
}
