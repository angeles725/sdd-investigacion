// Package lint owns the rsdd commands for block lint with compiled rule packs and review-slices.
package lint

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/lint/reviewslices"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "block", Group: "lint", Summary: "lint a block file or corpus against the generic block rules", Run: Run},
	// PlainExit3: exit 3 is the script's "git not found", printed on stdout with nothing on stderr; the generic
	// "DEGRADED:" stderr line cli.Run would append is not part of its contract.
	{Name: "review-slices", Group: "lint", Summary: "plan reviewable slices of merge-base..HEAD, cut only at commit boundaries (plan-review-slices.sh)", Run: reviewslices.Run, PlainExit3: true},
}
