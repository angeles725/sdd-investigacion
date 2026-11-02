package helpers

import (
	"errors"
	"os"
	"path"
	"strconv"
	"strings"
)

// Env is what the bind helpers read from the machine, injected: the working
// directory relative tool paths resolve against, and Home, the value of
// os.path.expanduser("~") (the belt check resolves it with realpath).
type Env struct {
	Cwd  string
	Home string
}

// Writable is one (host_dir, sandbox_path) pair of bind_venv's writable list.
type Writable struct{ Host, Sandbox string }

// blockedBindRoots is _BLOCKED_BIND_ROOTS.
var blockedBindRoots = map[string]bool{
	"/": true, "/home": true, "/root": true, "/usr": true, "/bin": true, "/sbin": true, "/lib": true, "/lib64": true,
	"/etc": true, "/tmp": true, "/proc": true, "/sys": true, "/dev": true, "/run": true,
}

// etcBindTryAllowed is _ETC_BIND_TRY_ALLOWED; its sorted repr is part of the
// refusal message.
var etcBindTryAllowed = map[string]bool{"/etc/passwd": true, "/etc/group": true}

const (
	etcAllowedList = "['/etc/group', '/etc/passwd']"
	venvBindMsg    = "tool is not inside a Python venv (wrapper script?); point RSDD_<TOOL> at the venv's bin/<tool>"
	rsddPrefix     = "/tmp/rsdd/"
)

// AssertSafeBindRoot is assert_safe_bind_root: it refuses a blocked system
// root, a path too broad (/home/<user>) or too shallow, and the real home
// directory. A failed realpath of Home (a relative Home with no Cwd) is
// returned raw, as an OSError would be.
func AssertSafeBindRoot(e Env, resolved string) error {
	s := pyNorm(resolved)
	if blockedBindRoots[s] {
		return newErr(KindBindScope, "path is a blocked system root: "+pyRepr(s), nil)
	}
	parts := pyParts(s)
	if strings.HasPrefix(s, "/home/") {
		if len(parts) < 4 {
			return newErr(KindBindScope, "path too broad to bind safely (require /home/<user>/<subdir> or deeper, got "+
				strconv.Itoa(len(parts))+" parts): "+pyRepr(s), nil)
		}
	} else if len(parts) < 3 {
		return newErr(KindBindScope, "path too shallow to bind safely ("+strconv.Itoa(len(parts))+" parts, need ≥3): "+pyRepr(s), nil)
	}
	home, err := realpath(e.Home, e.Cwd)
	if err != nil {
		return err
	}
	if s == home {
		return newErr(KindBindScope, "path resolves to the real home directory: "+pyRepr(s), nil)
	}
	return nil
}

// VenvRootFor is venv_root_for: the venv root of a tool executable, after the
// scope guard and the pyvenv.cfg marker.
func VenvRootFor(e Env, toolExe string) (string, error) {
	tool := pyNorm(toolExe)
	real, err := realpath(tool, e.Cwd)
	if err != nil {
		return "", err
	}
	parent := path.Dir(real)
	if path.Base(parent) != "bin" {
		return "", newErr(KindVenvBind, "tool executable is not inside a 'bin/' directory: "+tool, nil)
	}
	root := path.Dir(parent)
	if err := AssertSafeBindRoot(e, root); err != nil {
		var he *Error
		if errors.As(err, &he) {
			return "", newErr(KindVenvBind, venvBindMsg, err)
		}
		return "", err
	}
	if fi, err := os.Stat(root + "/pyvenv.cfg"); err != nil || !fi.Mode().IsRegular() {
		return "", newErr(KindVenvBind, venvBindMsg, nil)
	}
	return root, nil
}

// BindVenv is bind_venv: prefix (ending in "--") extended with the tool's venv
// read-only bind, the allowed /etc entries and the writable directories. The
// input slice is never modified.
func BindVenv(e Env, prefix []string, toolExe string, etcRoBindTry []string, writable []Writable) ([]string, error) {
	if len(prefix) == 0 || prefix[len(prefix)-1] != "--" {
		return nil, newErr(KindVenvBind, "bwrap prefix must end with '--' (produced by adapter_core.sandbox())", nil)
	}
	root, err := VenvRootFor(e, toolExe)
	if err != nil {
		return nil, err
	}
	extra := []string{}
	parts := pyParts(root)
	for i := 1; i < len(parts); i++ {
		extra = append(extra, "--dir", "/"+strings.Join(parts[1:i+1], "/"))
	}
	extra = append(extra, "--ro-bind", root, root)
	for _, entry := range etcRoBindTry {
		if !etcBindTryAllowed[entry] {
			return nil, newErr(KindVenvBind, "etc_ro_bind_try entry "+pyRepr(entry)+" is not in the allowed set "+etcAllowedList+
				"; only /etc/passwd and /etc/group are permitted (required by vivisect's getpwuid call)", nil)
		}
		extra = append(extra, "--ro-bind-try", entry, entry)
	}
	for _, w := range writable {
		sandbox := pyNormpath(w.Sandbox)
		if !strings.HasPrefix(sandbox, rsddPrefix) {
			return nil, newErr(KindVenvBind, "writable sandbox_path must start with '/tmp/rsdd/': "+pyRepr(sandbox), nil)
		}
		host := pyNorm(w.Host)
		fi, err := os.Lstat(host)
		if err != nil {
			return nil, newErr(KindVenvBind, "writable host_dir does not exist or is not accessible: "+host, err)
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return nil, newErr(KindVenvBind, "writable host_dir must not be a symlink: "+host, nil)
		}
		if !fi.IsDir() {
			return nil, newErr(KindVenvBind, "writable host_dir must be a directory: "+host, nil)
		}
		extra = append(extra, "--dir", sandbox, "--bind", host, sandbox)
	}
	out := append([]string{}, prefix[:len(prefix)-1]...)
	return append(append(out, extra...), "--"), nil
}
