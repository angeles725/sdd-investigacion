package adapter

import (
	hexenc "encoding/hex"
	"os"
	pathpkg "path"
	"regexp"
	"strings"
)

// Env is what the manifest code reads from the process: the working directory relative paths
// resolve against and the environment (HOME decides what "~" means). Both are injected.
type Env struct {
	Cwd string
	Get func(string) string
}

func (e Env) get(k string) string {
	if e.Get == nil {
		return ""
	}
	return e.Get(k)
}

// absPath anchors p to the working directory without normalising it.
func (e Env) absPath(p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return e.Cwd + "/" + p
}

var percentRun = regexp.MustCompile(`(?:%[0-9A-Fa-f]{2})+`)

// pyUnquote is urllib.parse.unquote(s): each run of %XX escapes is decoded as UTF-8, invalid bytes
// becoming U+FFFD. (Python writes one U+FFFD per invalid byte, Go one per run of them; the manifest
// checks only look for dots, separators and schemes, which U+FFFD is none of.)
func pyUnquote(s string) string {
	return percentRun.ReplaceAllStringFunc(s, func(run string) string {
		b, _ := hexenc.DecodeString(strings.ReplaceAll(run, "%", ""))
		return strings.ToValidUTF8(string(b), "\uFFFD")
	})
}

// pyName is pathlib.PurePosixPath(p).name and pyParent its .parent, for the canonical paths the
// manifest holds (path.Base and path.Dir also collapse a ".." segment, which pathlib keeps).
func pyName(p string) string {
	if n := pathpkg.Base(p); n != "/" && n != "." {
		return n
	}
	return ""
}

func pyParent(p string) string { return pathpkg.Dir(p) }

// pyJoin is str(PurePosixPath(a) / b) for a relative b.
func pyJoin(a, b string) string { return pyNorm(a + "/" + b) }

// isRelativeTo is the success of PurePosixPath(p).relative_to(root), for resolved absolute paths.
func isRelativeTo(p, root string) bool {
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// expandUser is the "~" case of Path.expanduser(): a leading "~" component becomes $HOME. "~user" is
// not expanded and an unset HOME leaves the path as it is (a relative path, which the callers confine to
// the analysis root).
func expandUser(value string, env Env) string {
	norm := pyNorm(value)
	parts := pyParts(norm)
	home := strings.TrimRight(env.get("HOME"), "/")
	if len(parts) == 0 || parts[0] != "~" || home == "" {
		return norm
	}
	return pyNorm(strings.Join(append([]string{home}, parts[1:]...), "/"))
}

// statTuple is the identity the Python code compares before and after reading.
type statTuple struct {
	dev, ino         uint64
	mode             uint32
	size             int64
	mtimeNs, ctimeNs int64
}

// statPath is os.stat(path) (follows symlinks).
func statPath(path string) (statTuple, error) {
	st, err := statSys(path)
	if err != nil {
		return statTuple{}, osError(err, path)
	}
	return st, nil
}

// isFile is Path.is_file(): any failure is False.
func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
