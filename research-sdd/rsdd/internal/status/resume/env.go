package resume

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// environ is the whole environment of the caller, as KEY=VALUE pairs (nil when the Stdio carries none).
func environ(s cli.Stdio) []string {
	if s.Environ == nil {
		return nil
	}
	return s.Environ()
}

// envValue is the last value of key in env and whether the key is set.
func envValue(env []string, key string) (string, bool) {
	for i := len(env) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(env[i], key+"="); ok {
			return v, true
		}
	}
	return "", false
}

// onPath is `command -v name >/dev/null`: a file named name in a PATH directory of env (an empty entry is the current
// directory; an unset PATH is the default of the exec package, /bin:/usr/bin). Like bash, it prefers an executable file
// and settles for the first non-executable one when there is none: the shell reports it found and then fails to run it.
func onPath(env []string, cwd, name string) bool {
	path, set := envValue(env, "PATH")
	if !set {
		path = "/bin:/usr/bin"
	}
	for _, dir := range strings.Split(path, ":") {
		if dir == "" {
			dir = "."
		}
		// An executable file wins, but bash settles for a non-executable one too (it fails later, when run), so
		// any non-directory entry named name answers true.
		if st, err := os.Stat(filepath.Join(abs(cwd, dir), name)); err == nil && !st.IsDir() {
			return true
		}
	}
	return false
}

// gitEnv is the environment of every git and gh call of resume-state: the caller's, without the GIT_* variables that
// would redirect the calls to another repository, and with GIT_OPTIONAL_LOCKS=0 so that no call refreshes an index or
// takes an optional lock (the command is read-only).
func gitEnv(env []string) []string {
	drop := map[string]bool{"GIT_DIR": true, "GIT_WORK_TREE": true, "GIT_COMMON_DIR": true, "GIT_INDEX_FILE": true, "GIT_OPTIONAL_LOCKS": true}
	var out []string
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if !drop[k] {
			out = append(out, kv)
		}
	}
	return append(out, "GIT_OPTIONAL_LOCKS=0")
}

// abs is a path as the shell would resolve it from the working directory.
func abs(cwd, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(cwd, p)
}
