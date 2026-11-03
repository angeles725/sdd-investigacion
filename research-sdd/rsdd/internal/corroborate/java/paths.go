package java

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Path helpers with the semantics of the pathlib calls corroborate_java.py made. They never read the working
// directory or the environment themselves: the caller passes both.

// failure is a typed refusal: its text is what follows "corroborate-java: " on stderr.
type failure struct{ msg string }

func (f *failure) Error() string { return f.msg }

func fail(format string, a ...any) error { return &failure{fmt.Sprintf(format, a...)} }

// pyNorm is how pathlib spells a path: empty components and "." components vanish (a trailing slash too), ".."
// stays; an empty result is ".".
func pyNorm(p string) string {
	parts := strings.Split(p, "/")
	kept := parts[:0]
	for _, c := range parts {
		if c != "" && c != "." {
			kept = append(kept, c)
		}
	}
	out := strings.Join(kept, "/")
	if strings.HasPrefix(p, "/") {
		return "/" + out
	}
	if out == "" {
		return "."
	}
	return out
}

// expandUser is Path.expanduser for a leading "~" or "~/": the home directory comes from HOME. "~name" is left as
// written (the user database is not consulted).
func expandUser(p, home string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home == "" {
			return p
		}
		return strings.TrimRight(home, "/") + p[1:]
	}
	return p
}

// absolute is Path.absolute(): the path anchored at cwd, normalised, symlinks and ".." untouched.
func absolute(p, cwd string) string {
	if strings.HasPrefix(p, "/") {
		return pyNorm(p)
	}
	return pyNorm(cwd + "/" + p)
}

// errnoText is the C library text Python puts after "[Errno N]".
func errnoText(e syscall.Errno) string {
	s := e.Error()
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// osFailure renders an OS error like str(OSError): "[Errno 2] No such file or directory: 'x'".
func osFailure(err error, name string) error {
	var errno syscall.Errno
	switch {
	case errors.As(err, &errno):
	case errors.Is(err, fs.ErrNotExist):
		errno = syscall.ENOENT
	default:
		return &failure{err.Error()}
	}
	msg := fmt.Sprintf("[Errno %d] %s", int(errno), errnoText(errno))
	if name != "" {
		msg += ": '" + name + "'"
	}
	return &failure{msg}
}

// resolveStrict is Path.resolve(strict=True): every component must exist.
func resolveStrict(p string) (string, error) {
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", osFailure(err, p)
	}
	return r, nil
}

// resolveLoose is Path.resolve(): symlinks are followed as far as the path exists, the rest is kept.
func resolveLoose(p string) string {
	var tail []string
	for dir := p; ; {
		if r, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(append([]string{r}, tail...)...)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return p
		}
		tail = append([]string{filepath.Base(dir)}, tail...)
		dir = parent
	}
}

// isSymlink is Path.is_symlink(): false for a missing path.
func isSymlink(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && fi.Mode()&os.ModeSymlink != 0
}

// pathExists is Path.exists(): it follows symlinks, so a dangling one does not exist.
func pathExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// isParentOrSame is `artifact == destination or destination in artifact.parents`.
func isParentOrSame(artifact, destination string) bool {
	return artifact == destination || strings.HasPrefix(artifact, strings.TrimRight(destination, "/")+"/")
}

// protectDestination refuses an output root that is, or contains, a protected artifact.
func protectDestination(destination string, protected []string) error {
	for _, artifact := range protected {
		if isParentOrSame(artifact, destination) {
			return fail("output root collides with protected artifact: %s", artifact)
		}
	}
	return nil
}

// canonicalDestination is canonical_destination: the output root as a new or existing real directory under a
// resolved parent, never a symlink.
func canonicalDestination(requested, home, cwd string) (string, error) {
	lexical := absolute(expandUser(requested, home), cwd)
	if isSymlink(lexical) {
		return "", fail("output root must not be a symlink")
	}
	name := filepath.Base(lexical)
	if lexical == "/" {
		name = ""
	}
	if name == "" {
		return "", fail("output root must name a new directory")
	}
	parent, err := resolveStrict(filepath.Dir(lexical))
	if err != nil {
		return "", err
	}
	destination := filepath.Join(parent, name)
	if isSymlink(destination) {
		return "", fail("output root must not be a symlink")
	}
	if fi, err := os.Stat(destination); err == nil {
		if !fi.IsDir() {
			return "", fail("output root must be a directory")
		}
		return resolveLoose(destination), nil
	}
	return destination, nil
}
