package kaitai

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
)

// scopeGuard is _toolchain_scope_guard: the generic bind-root predicate, re-raised with the adapter's own prefix.
func (e *env) scopeGuard(p string) error {
	err := helpers.AssertSafeBindRoot(helpers.Env{Cwd: e.cwd, Home: e.home}, p)
	var he *helpers.Error
	if errors.As(err, &he) && he.Kind == helpers.KindBindScope {
		return errors.New("path rejected by toolchain scope guard: " + he.Msg)
	}
	return err
}

// jdkHomeGuard validates a JDK home with its strong markers (bin/java and release).
func (e *env) jdkHomeGuard(home string) error {
	if err := e.scopeGuard(home); err != nil {
		return err
	}
	for _, m := range []string{"bin/java", "release"} {
		if !isFile(filepath.Join(home, m)) {
			return errors.New("JDK home missing expected marker " + filepath.Base(m) + ": " + home)
		}
	}
	return nil
}

func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// parents lists p then its ancestors up to "/".
func parents(p string) []string {
	out := []string{p}
	for p != "/" && p != "." && p != "" {
		p = filepath.Dir(p)
		out = append(out, p)
	}
	return out
}

// brewRootFor is _brew_root_for: the nearest ancestor holding both Cellar/ and bin/.
func brewRootFor(p string) (string, bool) {
	for _, d := range parents(p) {
		if !isDir(d) {
			continue
		}
		if isDir(filepath.Join(d, "Cellar")) && isDir(filepath.Join(d, "bin")) {
			return d, true
		}
	}
	return "", false
}

// bindTree is _bind_tree: --dir stubs for every ancestor, then --ro-bind of p.
func bindTree(p string) []string {
	var args []string
	parts := strings.Split(strings.TrimPrefix(filepath.Clean(p), "/"), "/")
	for i := 1; i <= len(parts); i++ {
		args = append(args, "--dir", "/"+strings.Join(parts[:i], "/"))
	}
	return append(args, "--ro-bind", p, p)
}

// ldSoStubFor is _ld_so_stub_for: recreate the brew <root>/lib/ld.so symlink inside the sandbox.
func ldSoStubFor(prefix string) []string {
	for _, d := range parents(prefix) {
		ld := filepath.Join(d, "lib", "ld.so")
		if fi, err := os.Lstat(ld); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(ld)
			if err != nil {
				continue
			}
			return []string{"--dir", filepath.Dir(ld), "--symlink", target, ld}
		}
	}
	return nil
}

// whichIn is shutil.which for a bare name over a PATH string.
func whichIn(name, search string) (string, bool) {
	for _, d := range strings.Split(search, ":") {
		if d == "" {
			continue
		}
		c := filepath.Join(d, name)
		if fi, err := os.Stat(c); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return c, true
		}
	}
	return "", false
}

func resolveStrict(p string) (string, error) {
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", err
	}
	return filepath.Abs(r)
}

// jdkHomeFor is _jdk_home_for: parent of bin/java, resolved.
func (e *env) jdkHomeFor() (string, error) {
	raw := e.getenvDefault("RSDD_JAVA", "java")
	if !filepath.IsAbs(raw) {
		found, ok := whichIn(raw, e.s.Env("PATH"))
		if !ok {
			return "", errors.New("java executable not found; install via brew or set RSDD_JAVA")
		}
		raw = found
	}
	resolved, err := resolveStrict(raw)
	if err != nil {
		return "", err
	}
	home := filepath.Dir(filepath.Dir(resolved))
	return home, e.jdkHomeGuard(home)
}

// kscExeFor is _ksc_exe_for: the resolved kaitai-struct-compiler.
func (e *env) kscExeFor() (string, error) {
	raw := e.getenvDefault("RSDD_KSC", "kaitai-struct-compiler")
	if !filepath.IsAbs(raw) {
		found, ok := whichIn(raw, e.s.Env("PATH"))
		if !ok {
			return "", errors.New("kaitai-struct-compiler not found; install via brew or set RSDD_KSC")
		}
		raw = found
	}
	if syscall.Access(raw, 1) != nil {
		return "", errors.New("ksc not executable: " + raw)
	}
	return resolveStrict(raw)
}

// bindJVMToolchain is _bind_jvm_toolchain: prefix (ending in "--") extended for ksc, the JDK and the writable gen dir.
func (e *env) bindJVMToolchain(prefix []string, ksc, jdkHome, genHost string) ([]string, error) {
	extra := []string{"--ro-bind-try", "/etc/alternatives", "/etc/alternatives"}
	brew, hasBrew := brewRootFor(ksc)
	if hasBrew {
		if err := e.scopeGuard(brew); err != nil {
			return nil, err
		}
		extra = append(extra, bindTree(brew)...)
		extra = append(extra, ldSoStubFor(brew)...)
	}
	if jb, ok := brewRootFor(jdkHome); ok && (!hasBrew || jb != brew) {
		if err := e.scopeGuard(jb); err != nil {
			return nil, err
		}
		extra = append(extra, bindTree(jb)...)
		extra = append(extra, ldSoStubFor(jb)...)
	}
	extra = append(extra, "--dir", "/tmp/rsdd/gen", "--bind", genHost, "/tmp/rsdd/gen")
	return spliceBeforeDashes(prefix, extra), nil
}

func spliceBeforeDashes(prefix, extra []string) []string {
	out := append([]string{}, prefix[:len(prefix)-1]...)
	return append(append(out, extra...), "--")
}

// bindKaitaiVenv is _bind_kaitai_venv: the rsdd-kaitai venv plus the brew Python its pyvenv.cfg points at.
func (e *env) bindKaitaiVenv(prefix []string, kaitaiPy string) ([]string, error) {
	venvRoot := filepath.Dir(filepath.Dir(kaitaiPy))
	if err := e.scopeGuard(venvRoot); err != nil {
		return nil, err
	}
	pyvenv := filepath.Join(venvRoot, "pyvenv.cfg")
	if !isFile(pyvenv) {
		return nil, errors.New("kaitai Python is not inside a venv (no pyvenv.cfg): " + venvRoot)
	}
	if rv, err := filepath.EvalSymlinks(venvRoot); err == nil {
		if h, err := filepath.EvalSymlinks(e.home); err == nil && rv == h {
			return nil, errors.New("kaitai Python venv must not be the home directory")
		}
	}
	text, err := os.ReadFile(pyvenv)
	if err != nil {
		return nil, err
	}
	cfg := map[string]string{}
	for _, line := range strings.Split(string(text), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			cfg[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	brewExe := cfg["executable"]
	if brewExe == "" {
		return nil, errors.New("pyvenv.cfg missing 'executable' key: " + pyvenv)
	}
	brewPrefix := filepath.Dir(filepath.Dir(brewExe))
	if err := e.scopeGuard(brewPrefix); err != nil {
		return nil, err
	}
	if !isFile(brewExe) {
		return nil, errors.New("brew Python executable not found: " + brewExe)
	}
	var optArgs []string
	if home := cfg["home"]; home != "" {
		optPy := filepath.Dir(home)
		if fi, err := os.Lstat(optPy); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(optPy)
			if err != nil {
				return nil, err
			}
			optArgs = []string{"--dir", filepath.Dir(optPy), "--symlink", target, optPy}
		}
	}
	var extra []string
	extra = append(extra, bindTree(venvRoot)...)
	extra = append(extra, bindTree(brewPrefix)...)
	extra = append(extra, optArgs...)
	extra = append(extra, ldSoStubFor(brewPrefix)...)
	return spliceBeforeDashes(prefix, extra), nil
}

// genStem is _get_gen_stem: the stem of the single .py ksc generated.
func genStem(dir string) (string, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var pys []string
	for _, f := range ents {
		if filepath.Ext(f.Name()) == ".py" && isFile(filepath.Join(dir, f.Name())) {
			pys = append(pys, f.Name())
		}
	}
	if len(pys) != 1 {
		sort.Strings(pys)
		q := make([]string, len(pys))
		for i, n := range pys {
			q[i] = "'" + n + "'"
		}
		return "", errors.New("expected exactly one generated .py in " + dir + ", found: [" + strings.Join(q, ", ") + "]")
	}
	return strings.TrimSuffix(pys[0], ".py"), nil
}
