package console

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

// TestGolden replays testdata/golden/<case>/ (adding-a-command.md section 3) through the same cli dispatch the
// binary uses, with the command's own registry entry, so the exit-3 contract (PlainExit3) is part of what is pinned.
// Every case here is one the legacy script answers without running any external tool, and the answer is the
// legacy script's, byte for byte: TestDifferential proves that for the same arguments.
func TestGolden(t *testing.T) {
	golden.Run(t, "testdata/golden", func(a []string, s cli.Stdio) int {
		return cli.Run([]cli.Command{Command}, a, s)
	})
}
