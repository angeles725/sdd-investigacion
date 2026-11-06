package show

import (
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// The seams of the remote-visibility block: the bounded gh probe, and `command -v gh`.
var (
	ghProbe = gh.Probe
	ghFound = commandFound
)

// commandFound is `command -v bin` run in dir: a name with a slash is a path, any other name is searched on the
// PATH of environ (an empty entry is the current directory). The program must be an executable regular file.
func commandFound(bin string, environ []string, dir string) bool {
	exec := func(p string) bool {
		if !strings.HasPrefix(p, "/") {
			p = dir + "/" + p
		}
		st, err := os.Stat(p)
		return err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0
	}
	if strings.Contains(bin, "/") {
		return exec(bin)
	}
	path := ""
	for _, kv := range environ {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = v
		}
	}
	for _, entry := range strings.Split(path, ":") {
		if entry == "" {
			entry = "."
		}
		if exec(entry + "/" + bin) {
			return true
		}
	}
	return false
}
