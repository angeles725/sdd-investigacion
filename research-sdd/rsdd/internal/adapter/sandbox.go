package adapter

import (
	"os"
	"strings"
)

// DefaultHost is the production Host: the fixed /tmp/rsdd mount point.
func DefaultHost(uid int, cwd string) Host { return Host{Root: "/tmp/rsdd", UID: uid, Cwd: cwd} }

// roInputBlockedRoots is _RO_INPUT_BLOCKED_ROOTS. "/" is handled by an explicit
// check; it would be a silent no-op here.
var roInputBlockedRoots = []string{"/home", "/root", "/etc", "/proc", "/sys", "/dev", "/run"}

func (h Host) exists(p string) bool {
	if h.Exists != nil {
		return h.Exists(p)
	}
	_, err := os.Stat(p)
	return err == nil
}

// Sandbox is adapter_core.sandbox (and its isolation_prefix alias): the
// hardened bwrap argv ending in "--". It creates and checks the private
// mount-point directory (h.Root) first, then validates every ro_input after
// resolving symlinks (root, restricted trees, missing paths are refused), and
// emits the fixed flag set in the Python order. env keeps the caller's order.
func Sandbox(h Host, bwrap string, env []EnvVar, roInputs []string) ([]string, error) {
	if err := checkMountpoint(h); err != nil {
		return nil, err
	}
	cmd := []string{
		bwrap,
		"--die-with-parent", "--new-session",
		"--unshare-net", "--unshare-pid",
		"--cap-drop", "ALL",
	}
	for _, d := range []string{"/usr", "/bin", "/sbin", "/lib", "/lib64"} {
		if h.exists(d) {
			cmd = append(cmd, "--ro-bind", d, d)
		}
	}
	for _, e := range []string{"/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d", "/etc/ssl/certs"} {
		cmd = append(cmd, "--ro-bind-try", e, e)
	}
	for _, in := range roInputs {
		real, err := realpath(in, false, h.Cwd)
		if err != nil {
			return nil, err
		}
		if real == "/" {
			return nil, &Error{Msg: "ro_input '" + in + "' is rejected: path resolves to the filesystem root"}
		}
		for _, blocked := range roInputBlockedRoots {
			if real == blocked || strings.HasPrefix(real, blocked+"/") {
				return nil, &Error{Msg: "ro_input '" + in + "' is rejected: path is at or under a restricted directory (" + blocked + ")"}
			}
		}
		if !h.exists(real) {
			return nil, &Error{Msg: "ro_input '" + in + "' does not exist on the host; a missing declared input is rejected to prevent silent omissions"}
		}
		cmd = append(cmd, "--ro-bind", real, real)
	}
	cmd = append(cmd,
		"--proc", "/proc",
		"--dev", "/dev",
		"--tmpfs", "/tmp/rsdd",
		"--dir", "/tmp/rsdd/home",
		"--dir", "/tmp/rsdd/cache",
		"--dir", "/tmp/rsdd/config",
		"--dir", "/tmp/rsdd/data",
		"--dir", "/tmp/rsdd/work",
		"--ro-bind", ".", "/tmp/rsdd/work",
	)
	for _, kv := range env {
		cmd = append(cmd, "--setenv", kv.Key, kv.Value)
	}
	return append(cmd, "--chdir", "/tmp/rsdd/work", "--"), nil
}

// checkMountpoint mirrors root.mkdir(0o700, exist_ok=True) then the lstat
// checks: a symlink, a foreign owner or any group/other permission bit is
// "unsafe Bubblewrap mountpoint". Failures of mkdir itself stay raw errors.
func checkMountpoint(h Host) error {
	if err := os.Mkdir(h.Root, 0o700); err != nil {
		if fi, serr := os.Stat(h.Root); !os.IsExist(err) || serr != nil || !fi.IsDir() {
			return err
		}
	}
	fi, err := os.Lstat(h.Root)
	if err != nil {
		return err
	}
	uid, ok := ownerUID(fi)
	if fi.Mode()&os.ModeSymlink != 0 || !ok || uid != h.UID || fi.Mode().Perm()&0o077 != 0 {
		return &Error{Msg: "unsafe Bubblewrap mountpoint"}
	}
	return nil
}
