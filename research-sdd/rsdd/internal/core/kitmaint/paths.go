package kitmaint

import (
	"os"
	"path/filepath"
	"strings"
)

// IsDir is `[ -d p ]`.
func IsDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// Abs makes p absolute against cwd without resolving anything (a relative p is cwd/p, as `cd` would see it).
func Abs(cwd, p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return cwd + "/" + p
}

// ResolveDir is `cd -- DIR && pwd -P`.
func ResolveDir(cwd, p string) (string, error) {
	return filepath.EvalSymlinks(filepath.Clean(Abs(cwd, p)))
}

// PhysPath is kit_phys_path: the physical path of P even when P does not exist yet (the nearest existing ancestor
// is resolved and the rest appended).
func PhysPath(cwd, p string) (string, error) {
	p = Abs(cwd, p)
	rest := ""
	for !IsDir(p) && p != "/" {
		rest = "/" + p[strings.LastIndex(p, "/")+1:] + rest
		p = p[:strings.LastIndex(p, "/")]
		if p == "" {
			p = "/"
		}
	}
	d, err := filepath.EvalSymlinks(filepath.Clean(p))
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(d, "/") + rest, nil
}

// StateDir is kit_state_dir: ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/pipeline.
func StateDir(getenv func(string) string) string {
	base := getenv("XDG_STATE_HOME")
	if base == "" {
		base = getenv("HOME") + "/.local/state"
	}
	return base + "/research-sdd/pipeline"
}

// Inside reports whether physical path p lies under dir (both physical): `case "$p/" in "$dir"/*`.
func Inside(p, dir string) bool { return strings.HasPrefix(p+"/", dir+"/") }
