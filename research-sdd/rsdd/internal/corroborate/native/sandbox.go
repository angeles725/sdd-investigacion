package native

import (
	"errors"
	"os"
	"syscall"
)

// safeR2 is the fixed radare2 command line, the safety contract of the adapter: -NN -S disable user
// configuration and plugins, -x and the fixed script disable the write, debug, profile and script surfaces,
// and the staged input is always input/target.bin. Never build this list from caller input.
var safeR2 = []string{"-NN", "-S", "-x", "-q", "-e", "scr.color=0", "-e", "scr.utf8=false",
	"-e", "scr.interactive=false", "-c", "aaa;aflj", "input/target.bin"}

// guestRoot is where Bubblewrap mounts its private tmpfs; the synthetic HOME/XDG/TMPDIR live under it.
const guestRoot = "/tmp/rsdd"

// envVar is one sandbox environment entry; the order is part of the recorded argv.
type envVar struct{ k, v string }

// sandboxEnv is the synthetic environment radare2 sees. r2Dir joins the search path so the staged analyzer
// finds its siblings; nothing else of the caller's environment crosses the boundary.
func sandboxEnv(r2Dir string) []envVar {
	return []envVar{
		{"HOME", guestRoot + "/home"}, {"XDG_CACHE_HOME", guestRoot + "/cache"}, {"XDG_CONFIG_HOME", guestRoot + "/config"},
		{"XDG_DATA_HOME", guestRoot + "/data"}, {"TMPDIR", guestRoot}, {"PATH", r2Dir + ":/usr/bin:/bin"},
		{"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}, {"TZ", "UTC"},
	}
}

// sandboxPrefix is the Bubblewrap command ending in "--": no network namespace, the host root read-only, a
// private tmpfs with synthetic home/cache/config/data, the staging directory as the working directory and the
// environment set explicitly. Appending the radare2 argv gives the full command.
func sandboxPrefix(bwrap string, env []envVar) []string {
	cmd := []string{bwrap, "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", guestRoot, "--dir", guestRoot + "/home",
		"--dir", guestRoot + "/cache", "--dir", guestRoot + "/config", "--dir", guestRoot + "/data",
		"--dir", guestRoot + "/work", "--ro-bind", ".", guestRoot + "/work"}
	for _, e := range env {
		cmd = append(cmd, "--setenv", e.k, e.v)
	}
	return append(cmd, "--chdir", guestRoot+"/work", "--")
}

// envList renders env as the KEY=VALUE list a process receives.
func envList(env []envVar) []string {
	out := make([]string, len(env))
	for i, e := range env {
		out[i] = e.k + "=" + e.v
	}
	return out
}

var errUnsafeMount = errors.New("unsafe Bubblewrap mountpoint")

// checkMountpoint makes the host directory Bubblewrap mounts its tmpfs over (mode 0700 when created) and
// refuses it when it is a symlink, owned by someone else, or open to group/other.
func checkMountpoint(root string, uid int) error {
	if err := os.Mkdir(root, 0o700); err != nil {
		if fi, serr := os.Stat(root); !os.IsExist(err) || serr != nil || !fi.IsDir() {
			return osError(err, root)
		}
	}
	fi, err := os.Lstat(root)
	if err != nil {
		return osError(err, root)
	}
	owner, ok := ownerUID(fi)
	if fi.Mode()&os.ModeSymlink != 0 || !ok || owner != uid || fi.Mode().Perm()&0o077 != 0 {
		return errUnsafeMount
	}
	return nil
}

//lint:ignore ST1005 the exact text is the legacy driver's message, kept for stderr parity
var errBwrapTrust = errors.New("Bubblewrap must be root-owned and non-writable")

// bwrapRootOwned is the launcher trust check: root-owned and not writable by group or other.
func bwrapRootOwned(fi os.FileInfo) error {
	owner, ok := ownerUID(fi)
	if !ok || owner != 0 || fi.Mode().Perm()&0o022 != 0 {
		return errBwrapTrust
	}
	return nil
}

// errno is the syscall error behind err, if any.
func errno(err error) (syscall.Errno, bool) {
	var e syscall.Errno
	ok := errors.As(err, &e)
	return e, ok
}
