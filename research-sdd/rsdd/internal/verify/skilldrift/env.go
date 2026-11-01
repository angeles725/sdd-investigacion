package skilldrift

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// envView is the caller's environment as the commands see it. cli.Stdio.Env cannot tell an unset variable from an empty one,
// and the scripts do (`${VAR+x}`), so the whole environment is read once from cli.Stdio.Environ.
type envView struct {
	s    cli.Stdio
	m    map[string]string
	list []string
}

func newEnvView(s cli.Stdio) envView {
	e := envView{s: s, m: map[string]string{}}
	if s.Environ != nil {
		e.list = s.Environ()
		for _, kv := range e.list {
			if k, v, ok := strings.Cut(kv, "="); ok {
				e.m[k] = v
			}
		}
	}
	return e
}

// lookup is `${KEY+x}`-aware: set reports whether the variable exists, even when empty.
func (e envView) lookup(key string) (val string, set bool) {
	if v, ok := e.m[key]; ok {
		return v, true
	}
	if e.s.Env != nil {
		if v := e.s.Env(key); v != "" {
			return v, true
		}
	}
	return "", false
}

// get is `${KEY:-}`.
func (e envView) get(key string) string { v, _ := e.lookup(key); return v }

// environ is the environment handed to a child: the whole caller environment.
func (e envView) environ() []string { return e.list }

// tmpDir is mktemp's directory: $TMPDIR, else /tmp.
func (e envView) tmpDir() string {
	if d := e.get("TMPDIR"); d != "" {
		return d
	}
	return "/tmp"
}

// findExe is `command -v name`: a name with a slash is itself, anything else is searched on pathEnv.
func findExe(name, pathEnv string) (string, bool) {
	if strings.Contains(name, "/") {
		return name, isExec(name)
	}
	for _, d := range filepath.SplitList(pathEnv) {
		if d == "" {
			d = "."
		}
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && isExec(p) {
			return p, true
		}
	}
	return "", false
}
