package kitsite

import (
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Cmd is one command under test: its data only.
type Cmd struct {
	Name         string
	Run          func([]string, cli.Stdio) int
	Args         func(Kit) []string
	Script       string   // the legacy script the command used to name
	Files        []string // what else the command needs under the kit
	Out, Err     string   // the expected stdout and stderr (placeholders: see Expand)
	RC           int
	RelAsWritten bool // a relative kit path is printed as written, not made absolute
	Warn         bool // the invalid-RESEARCH_SDD_KIT line is printed on stderr
}

// Suite is the commands of one package with how their kits are built.
type Suite struct {
	Profile Profile
	Bodies  map[string]string // file body by path under the kit root
	Cmds    []Cmd
}

// Kit builds the kit of c: the legacy script when withScript, then c.Files.
func (s Suite) Kit(t *testing.T, c Cmd, withScript bool) Kit {
	t.Helper()
	files := c.Files
	if withScript {
		files = append([]string{c.Script}, c.Files...)
	}
	return New(t, s.Profile, s.Bodies, files...)
}

// Check runs c against k and fails the test when stdout, stderr or the exit code differ. warn is the resolver's
// line expected before the command's own stderr (ignored unless c.Warn).
func (c Cmd) Check(t *testing.T, k Kit, kitEnv, cwd, warn string) {
	t.Helper()
	var args []string
	if c.Args != nil {
		args = c.Args(k)
	}
	out, errOut, rc := k.Run(c.Run, args, kitEnv, cwd)
	if !c.Warn {
		warn = ""
	}
	if msg := Compare(out, errOut, rc, Expand(c.Out, k.Root, k.Home), warn+Expand(c.Err, k.Root, k.Home), c.RC); msg != "" {
		t.Fatal(msg)
	}
}

// RunSuite runs the six scenarios of the kit-found tests for every command of the suite.
func RunSuite(t *testing.T, s Suite) {
	for _, c := range s.Cmds {
		t.Run(c.Name, func(t *testing.T) {
			t.Run("script present: the previous output", func(t *testing.T) {
				k := s.Kit(t, c, true)
				c.Check(t, k, k.Root, k.Home, "")
			})
			t.Run("legacy script missing: the same output", func(t *testing.T) {
				k := s.Kit(t, c, false)
				c.Check(t, k, k.Root, k.Home, "")
			})
			t.Run("kit path with a trailing slash", func(t *testing.T) {
				k := s.Kit(t, c, true)
				c.Check(t, k, k.Root+"/", k.Home, "")
			})
			t.Run("kit path with a dot segment", func(t *testing.T) {
				k := s.Kit(t, c, true)
				c.Check(t, k, filepath.Dir(k.Root)+"/./research-sdd", k.Home, "")
			})
			t.Run("relative kit path", func(t *testing.T) {
				k := s.Kit(t, c, true)
				t.Chdir(filepath.Dir(k.Root))
				if c.RelAsWritten {
					k.Root = "research-sdd"
				}
				c.Check(t, k, "research-sdd", filepath.Dir(k.Root), "")
			})
			t.Run("invalid RESEARCH_SDD_KIT: the line is on stderr, the output and exit code are the same", func(t *testing.T) {
				k := s.Kit(t, c, true)
				bare := k.Bare(t)
				c.Check(t, k, bare, k.Home, InvalidKitWarning(bare))
			})
		})
	}
}
