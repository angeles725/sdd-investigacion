package hook

import (
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Names of the environment variables the predicates read.
const (
	envCeiling = "RSDD_HOOK_WIRING_CEILING"
	envHome    = "HOME"

	// The Claude Code history root of LaunchState: the test seam wins over CLAUDE_CONFIG_DIR, which wins over HOME.
	envProjectsDir = "RSDD_CLAUDE_PROJECTS_DIR"
	envConfigDir   = "CLAUDE_CONFIG_DIR"
)

// Env carries what the predicates read from the outside world. Cwd stands in
// for $PWD of the bash library, Getenv for its environment reads and ReadFile
// is the seam the settings.json read goes through (nil means os.ReadFile).
type Env struct {
	Cwd      string
	Getenv   func(string) string
	ReadFile func(string) ([]byte, error)
}

// EnvFrom builds an Env from the process boundary.
func EnvFrom(s cli.Stdio) Env { return Env{Cwd: s.Cwd, Getenv: s.Env} }

func (e Env) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func (e Env) readFile(p string) ([]byte, error) {
	if e.ReadFile != nil {
		return e.ReadFile(p)
	}
	return os.ReadFile(p)
}
