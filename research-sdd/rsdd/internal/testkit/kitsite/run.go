package kitsite

import (
	"bytes"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Profile is the environment a command runs in besides HOME, RESEARCH_HOME and RESEARCH_SDD_KIT.
type Profile int

const (
	// SystemPath runs with PATH=/usr/bin:/bin.
	SystemPath Profile = iota
	// NoPath runs with a PATH that holds nothing (<home>/nobin, which a test may fill), the kit stale check off and
	// TMPDIR=<home>.
	NoPath
)

// Run executes the command with RESEARCH_SDD_KIT=kitEnv and the working directory cwd, on a hermetic Stdio, and
// returns what it wrote and its exit code.
func (k Kit) Run(run func([]string, cli.Stdio) int, args []string, kitEnv, cwd string) (out, errOut string, rc int) {
	env := map[string]string{"HOME": k.Home, "RESEARCH_HOME": filepath.Join(k.Home, "rh"), "RESEARCH_SDD_KIT": kitEnv}
	switch k.profile {
	case NoPath:
		env["PATH"] = filepath.Join(k.Home, "nobin")
		env["RESEARCH_SDD_KIT_STALE_CHECK"] = "off"
		env["TMPDIR"] = k.Home
	default:
		env["PATH"] = "/usr/bin:/bin"
	}
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Cwd: cwd,
		Env:   func(key string) string { return env[key] },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) },
		Environ: func() []string {
			var l []string
			for key, v := range env {
				l = append(l, key+"="+v)
			}
			return l
		}}
	rc = run(args, s)
	return o.String(), e.String(), rc
}
