// Package retro owns the rsdd commands for retro grammar, markers, staging and reconciliation.
// See docs/adding-a-command.md.
package retro

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/reconcile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/stage"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/stageissues"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/verifyretro"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{stageissues.Command, reconcile.Command, verifyretro.Command, stage.Command}
