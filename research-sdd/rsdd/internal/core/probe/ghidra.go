package probe

import (
	"sort"
	"strings"
)

// GhidraHome is rsdd_resolve_ghidra_home: ANALYZE_HEADLESS (an executable inside a support/ directory),
// then GHIDRA_HOME and GHIDRA_INSTALL_DIR (each authoritative), then analyzeHeadless on PATH inside
// support/, the brew ghidra libexec, and the /opt/ghidra* roots newest version first.
func (p *Prober) GhidraHome() (string, error) {
	if v, set := p.lookup("ANALYZE_HEADLESS"); set {
		if !p.isExec(v) || posixBase(posixDir(v)) != "support" {
			return "", &Degraded{Tool: "ghidra", Override: "ANALYZE_HEADLESS"}
		}
		return posixDir(posixDir(v)), nil
	}
	for _, k := range []string{"GHIDRA_HOME", "GHIDRA_INSTALL_DIR"} {
		if v, set := p.lookup(k); set {
			if !p.hasHeadless(v) {
				return "", &Degraded{Tool: "ghidra", Override: k}
			}
			return v, nil
		}
	}
	if h, _ := p.commandV("analyzeHeadless"); p.isExec(h) && posixBase(posixDir(h)) == "support" {
		return posixDir(posixDir(h)), nil
	}
	if c := p.brewPath("/opt/ghidra/libexec"); c != "" && p.hasHeadless(c) {
		return c, nil
	}
	opt := p.globNames(p.root+"/opt/", "ghidra", "")
	// sort -Vr: filevercmp, ties broken by byte order, all reversed.
	sort.SliceStable(opt, func(i, j int) bool {
		if c := filevercmp(opt[i], opt[j]); c != 0 {
			return c > 0
		}
		return opt[i] > opt[j]
	})
	for _, c := range opt {
		if p.hasHeadless(c) {
			return c, nil
		}
	}
	return "", &Degraded{Tool: "ghidra"}
}

func (p *Prober) hasHeadless(home string) bool { return p.isExec(home + "/support/analyzeHeadless") }

// trimSlashes drops trailing slashes, keeping "/" for an all-slash path.
func trimSlashes(path string) string {
	if t := strings.TrimRight(path, "/"); t != "" || path == "" {
		return t
	}
	return "/"
}

// posixDir is coreutils dirname.
func posixDir(path string) string {
	t := trimSlashes(path)
	i := strings.LastIndex(t, "/")
	if i < 0 {
		return "."
	}
	if d := strings.TrimRight(t[:i], "/"); d != "" {
		return d
	}
	return "/"
}

// posixBase is coreutils basename.
func posixBase(path string) string {
	t := trimSlashes(path)
	if t == "/" {
		return t
	}
	return t[strings.LastIndex(t, "/")+1:]
}
