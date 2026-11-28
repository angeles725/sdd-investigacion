package lint

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

// TestReviewSlicesGolden pins `rsdd lint review-slices` through the real dispatcher (this domain's own table: a domain
// cannot import internal/commands). The cases are the ones that need no repository: usage, --max-lines, an absent
// --cwd and the typed "git not found" (exit 3 with an EMPTY stderr: the command is registered PlainExit3). The runs
// that plan a repository are the differential and replay tests of internal/lint/reviewslices.
func TestReviewSlicesGolden(t *testing.T) {
	golden.Run(t, "testdata/golden", func(a []string, s cli.Stdio) int { return cli.Run(Commands, a, s) })
}
