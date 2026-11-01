package gate

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

// TestGolden pins the command through the real dispatcher. The domain cannot import internal/commands, so the
// table under test is this package's own Commands.
func TestGolden(t *testing.T) {
	golden.Run(t, "testdata/golden", func(a []string, s cli.Stdio) int { return cli.Run(Commands, a, s) })
}
