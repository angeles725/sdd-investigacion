// Package eval owns the rsdd commands that score research-sdd runs (loop transcripts and profile evals).
// See docs/adding-a-command.md.
package eval

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/eval/scoreloop"
)

// Commands is this domain's contribution to the command table. A unit adds its entries here and never edits
// internal/commands beyond its one registry line.
var Commands = []cli.Command{scoreloop.Command}
