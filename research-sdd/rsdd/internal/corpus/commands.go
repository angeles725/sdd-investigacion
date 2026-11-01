// Package corpus owns the rsdd commands for corpus tooling (init, archive, state-update, append-row, census, profile, coverage, ensure-remote).
// It is a stub until a porting unit fills it; see docs/adding-a-command.md.
package corpus

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corpus/ensureremote"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "ensure-remote", Group: "corpus", Summary: "create a PRIVATE-by-construction GitHub remote for a corpus and push it", Run: ensureremote.Run},
}
