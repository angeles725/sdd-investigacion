// Package lint owns the rsdd commands for block lint with compiled rule packs and review-slices.
package lint

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "block", Group: "lint", Summary: "lint a block file or corpus against the generic block rules", Run: Run},
}
