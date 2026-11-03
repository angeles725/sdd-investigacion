package firmware

import (
	"errors"
	"os"
)

// envVar is one --setenv pair; the sandbox keeps the order.
type envVar struct{ key, value string }

// sandboxEnv is the fixed environment of the analyzer run: private home and caches under the sandbox's own
// tmpfs, a fixed PATH, a fixed locale and zone.
func sandboxEnv(path string) []envVar {
	return []envVar{
		{"HOME", "/tmp/rsdd/home"}, {"XDG_CACHE_HOME", "/tmp/rsdd/cache"}, {"XDG_CONFIG_HOME", "/tmp/rsdd/config"},
		{"XDG_DATA_HOME", "/tmp/rsdd/data"}, {"TMPDIR", "/tmp/rsdd"}, {"PATH", path},
		{"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}, {"TZ", "UTC"},
	}
}

// environ is env as KEY=VALUE pairs, the form a process environment takes.
func environ(env []envVar) []string {
	out := make([]string, len(env))
	for i, kv := range env {
		out[i] = kv.key + "=" + kv.value
	}
	return out
}

// envMap is env as the manifest records it.
func envMap(env []envVar) map[string]any {
	m := make(map[string]any, len(env))
	for _, kv := range env {
		m[kv.key] = kv.value
	}
	return m
}

var errMountpoint = refusal("unsafe Bubblewrap mountpoint")

// sandbox is the bubblewrap prefix: no network, no capabilities, a read-only view of the host, a private tmpfs
// under /tmp/rsdd holding only the stage (the working directory) read-only, and the fixed environment. root is
// the host's own /tmp/rsdd: it is created private if missing, and must be a real directory owned by uid that
// nobody else can enter, or the sandbox refuses to start.
func sandbox(bwrap string, env []envVar, root string, uid uint64) ([]string, error) {
	if err := os.Mkdir(root, 0o700); err != nil {
		if fi, serr := os.Stat(root); !errors.Is(err, os.ErrExist) || serr != nil || !fi.IsDir() {
			return nil, osError(err, root)
		}
	}
	fi, err := os.Lstat(root)
	if err != nil {
		return nil, osError(err, root)
	}
	owned, ok := owner(fi)
	if fi.Mode()&os.ModeSymlink != 0 || !ok || owned != uid || fi.Mode().Perm()&0o077 != 0 {
		return nil, errMountpoint
	}
	cmd := []string{bwrap, "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL", "--ro-bind", "/", "/",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/home", "--dir", "/tmp/rsdd/cache",
		"--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data", "--dir", "/tmp/rsdd/work", "--ro-bind", ".", "/tmp/rsdd/work"}
	for _, kv := range env {
		cmd = append(cmd, "--setenv", kv.key, kv.value)
	}
	return append(cmd, "--chdir", "/tmp/rsdd/work", "--"), nil
}

// probeScript fails when any capability set of the sandboxed process is non-empty.
const probeScript = "! grep -Eq '^Cap(Inh|Prm|Eff|Bnd|Amb):.*[1-9a-fA-F]' /proc/self/status"
