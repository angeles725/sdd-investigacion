// Package hygiene owns the rsdd commands that look for what a run leaves behind. See docs/adding-a-command.md.
package hygiene

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/hygiene/cleancheck"
)

// Commands is this domain's contribution to the command table. A unit adds its entries here and never edits
// internal/commands beyond the one line that names the domain.
var Commands = []cli.Command{{
	Name:    "clean-check",
	Group:   "hygiene",
	Summary: "list the leftovers a run should not leave behind: untracked files, stale tmp, scratchpad evidence, retention (port of clean-check.sh)",
	Run:     cleancheck.Run,
	// Exit 3 is the script's degraded state and prints its own typed lines; a generic DEGRADED: line would change them.
	PlainExit3: true,
}}
