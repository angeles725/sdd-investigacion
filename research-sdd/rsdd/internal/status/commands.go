// Package status owns the rsdd commands for status, resume and score-loop.
// `status show` is being ported from research-sdd-status.sh in slices (issue #2549); see docs/adding-a-command.md.
package status

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/status/resume"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/status/show"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "show", Group: "status", Summary: "structured status and next-gap for a corpus (port in progress: args, --emit-token, state pick)", Run: show.Run},
	resume.StateCommand,
	resume.RenderCommand,
}
