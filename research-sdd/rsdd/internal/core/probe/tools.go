package probe

import "strings"

// R2 is rsdd_resolve_r2: R2 (authoritative), r2 on PATH, the brew radare2, then $RSDD_R2_USRBIN
// (default /usr/bin/r2).
func (p *Prober) R2() (string, error) {
	usr := p.get("RSDD_R2_USRBIN")
	if usr == "" {
		usr = p.root + "/usr/bin/r2"
	}
	return p.override("r2", "R2", "r2", p.brewPath("/opt/radare2/bin/r2"), usr)
}

// ILSpy is rsdd_resolve_ilspy: ILSPYCMD (authoritative), ilspycmd on PATH, then
// $HOME/.dotnet/tools/ilspycmd.
func (p *Prober) ILSpy() (string, error) {
	return p.override("ilspycmd", "ILSPYCMD", "ilspycmd", p.get("HOME")+"/.dotnet/tools/ilspycmd")
}

// override resolves an executable: the variable key when set (authoritative), else cmd on PATH, else the
// first executable of cands (an empty candidate is skipped).
func (p *Prober) override(tool, key, cmd string, cands ...string) (string, error) {
	if v, set := p.lookup(key); set {
		if p.isExec(v) {
			return v, nil
		}
		return "", &Degraded{Tool: tool, Override: key}
	}
	if c, _ := p.commandV(cmd); p.isExec(c) {
		return c, nil
	}
	for _, c := range cands {
		if p.isExec(c) {
			return c, nil
		}
	}
	return "", &Degraded{Tool: tool}
}

// SystemPkgConfigPath is rsdd_system_pkgconfig_path: RSDD_SYSTEM_PKGCONFIG_PATH, else the existing
// /usr/lib/*-linux-gnu/pkgconfig, /usr/lib/pkgconfig and /usr/share/pkgconfig directories joined by ':'.
// ok is false when there is none (the shell's return 1).
func (p *Prober) SystemPkgConfigPath() (string, bool) {
	if v := p.get("RSDD_SYSTEM_PKGCONFIG_PATH"); v != "" {
		return v, true
	}
	var dirs []string
	for _, d := range p.globNames(p.root+"/usr/lib/", "", "-linux-gnu") {
		dirs = append(dirs, d+"/pkgconfig")
	}
	dirs = append(dirs, p.root+"/usr/lib/pkgconfig", p.root+"/usr/share/pkgconfig")
	var out []string
	for _, d := range dirs {
		if p.isDir(d) {
			out = append(out, d)
		}
	}
	return strings.Join(out, ":"), len(out) > 0
}
