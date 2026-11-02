// Package niagara owns the rsdd commands for Niagara tooling.
// See docs/adding-a-command.md.
package niagara

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/palette"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "palette-lexicon", Group: "niagara", Summary: "palette/lexicon/agent census of an extracted N4 module (palette-lexicon.v1)", Run: palette.Run},
}
