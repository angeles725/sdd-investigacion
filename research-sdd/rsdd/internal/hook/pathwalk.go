package hook

import (
	"os"
	"strings"
)

// AbsPath is the port of _hw_abspath: p made absolute (prefixed with cwd when
// relative) with every "." and ".." component collapsed textually. No symlink
// is resolved and the filesystem is not touched.
//
// The collapse is purely textual on purpose: for ".../link/.." the kernel
// resolves ".." after following the symlink, this function does not, and
// FindGitRoot's raw-target check exists to answer that difference.
func AbsPath(cwd, p string) string {
	d := p
	if !strings.HasPrefix(d, "/") {
		d = cwd + "/" + d
	}
	rest := strings.TrimPrefix(d, "/")
	result := ""
	for last := false; !last; {
		var part string
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			part, rest = rest[:i], rest[i+1:]
		} else {
			part, last = rest, true
		}
		switch part {
		case "", ".":
		case "..":
			// ${result%/*}: drop the last component; nothing to drop at the root.
			if i := strings.LastIndexByte(result, '/'); i >= 0 {
				result = result[:i]
			}
		default:
			result += "/" + part
		}
	}
	if result == "" {
		result = "/"
	}
	return result
}

// exists is `[ -e path ]`: true when the path resolves (symlinks followed).
func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// FindGitRoot is the port of _hw_find_git_root. It returns the nearest
// ancestor of target (inclusive) that owns a `.git` entry, file or directory,
// or "" when there is none before "/" or before the RSDD_HOOK_WIRING_CEILING
// directory. targetIsRoot reports the raw-target case: the target as spelled
// owns a `.git`, and root is then the spelled (absolute, not collapsed) path.
// In every other outcome targetIsRoot is false and root is a real git root or "".
func FindGitRoot(e Env, target string) (root string, targetIsRoot bool) {
	d := AbsPath(e.Cwd, target)
	ceiling := ""
	if c := e.getenv(envCeiling); c != "" {
		ceiling = AbsPath(e.Cwd, c)
	}
	// RAW-TARGET CHECK (kit issue #1153): the kernel resolves ".." after a symlink and
	// the textual collapse does not, so a target spelled ".../link/.." can name a
	// different directory than d. If the spelled target owns a .git it is its own root.
	// The ceiling still wins for the collapsed path.
	raw := target
	if !strings.HasPrefix(raw, "/") {
		raw = e.Cwd + "/" + raw
	}
	if (ceiling == "" || d != ceiling) && exists(raw+"/.git") {
		return raw, true
	}
	for {
		if ceiling != "" && d == ceiling {
			return "", false
		}
		if exists(d + "/.git") {
			return d, false
		}
		if d == "/" {
			return "", false
		}
		if !strings.Contains(d, "/") { // ${d%/*} would not progress: fail closed
			return "", false
		}
		d = d[:strings.LastIndexByte(d, '/')] // ${d%/*}
		if d == "" {
			d = "/"
		}
	}
}
